#define PERL_NO_GET_CONTEXT     /* we want efficiency */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#define PROBE_TYPE_NONE      0
#define PROBE_TYPE_ONCE      1
#define PROBE_TYPE_PERMANENT 2

#define PROBE_ACTION_LOOKUP  0
#define PROBE_ACTION_REMOVE  1

#define PROBE_SETTINGS_TYPE_INDEX 0
#define PROBE_SETTINGS_ARGS_INDEX 1

#define PROBE_MAX_EVAL_SKIP_DEPTH 10

/*
 * Use preprocessor macros for time-sensitive operations.
 */
#define probe_is_enabled() !!probe_enabled

static Perl_ppaddr_t probe_nextstate_orig = 0;
static int probe_installed = 0;
static int probe_enabled = 0;
static HV* probe_hash = 0;
static SV* probe_trigger_cb = 0;

static void probe_enable(void);
static void probe_disable(void);
static int probe_is_installed(void);
static void probe_install(pTHX);
static void probe_remove(pTHX);

#define DEBUG 0

#define INFO(x) do { if (DEBUG > 0) dbg_printf x; } while (0)
#define TRACE(x) do { if (DEBUG > 1) dbg_printf x; } while (0)

void dbg_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

static void probe_invoke_callback(pTHX_ const char* file, int line, SV* user_arg, SV* callback)
{
    int count;

    dSP;

    ENTER;
    SAVETMPS;

    PUSHMARK (SP);
    EXTEND(SP, user_arg ? 3 : 2);
    XPUSHs(sv_2mortal(newSVpv(file, 0)));
    XPUSHs(sv_2mortal(newSViv(line)));
    if (user_arg) {
        XPUSHs(user_arg);
    }
    PUTBACK;

    count = call_sv(callback, G_VOID|G_DISCARD);
    if (count != 0) {
        croak("probe trigger should have zero return values");
    }

    FREETMPS;
    LEAVE;
}

static bool probe_lookup(pTHX_ const char* file, int line, int action)
{
    U32 klen = strlen(file);
    char kstr[20];
    SV** rlines = 0;
    HV* lines = 0;

    rlines = hv_fetch(probe_hash, file, klen, 0);
    if (rlines) {
        lines = (HV*) SvRV(*rlines);
        TRACE(("PROBE found entry for file [%s]: %p\n", file, lines));
    } else {
        return false;
    }

    klen = sprintf(kstr, "%d", line);
    if (hv_exists(lines, kstr, klen)) {
        if (action == PROBE_ACTION_REMOVE) {
            /* TODO: remove file name when last line for file was removed? */
            hv_delete(lines, kstr, klen, G_DISCARD);
            INFO(("PROBE removed entry for line [%s]\n", kstr));
        }
        return true;
    } else {
        return false;
    }

    /* catch any mistakes */
    return false;
}

static AV* probe_settings(pTHX_ const char* file, int line)
{
    U32 klen = strlen(file);
    char kstr[20];
    SV** rlines = 0;
    HV* lines = 0;
    SV** rsettings = 0;
    AV* settings = 0;

    rlines = hv_fetch(probe_hash, file, klen, 0);
    if (!rlines) {
        return 0;
    }
    lines = (HV*) SvRV(*rlines);

    klen = sprintf(kstr, "%d", line);
    rsettings = hv_fetch(lines, kstr, klen, 0);
    if (!rsettings) {
        return 0;
    }

    if (!SvROK(*rsettings) || SvTYPE(SvRV(*rsettings)) != SVt_PVAV) {
        croak("Devel::Probe settings must be an ARRAY ref");
    }

    settings = (AV*) SvRV(*rsettings);
    return settings;
}

/*
 * This function will run for every single line in your Perl code.
 * You would do well to make it as cheap as possible.
 */
static OP* probe_nextstate(pTHX)
{
    OP* ret = probe_nextstate_orig(aTHX);

    do {
        const PERL_CONTEXT *cx;
        const char* file = 0;
        int line = 0;
        int caller_line = 0;
        int caller_level = 0;
        AV* settings = 0;
        SV* user_callback_arg = 0;
        int type = PROBE_TYPE_NONE;

        if (!probe_is_enabled()) {
            break;
        }

        file = CopFILE(PL_curcop);
        line = CopLINE(PL_curcop);
        /* Walk up the stack until we get to a non-string-eval frame */
        while (caller_level < PROBE_MAX_EVAL_SKIP_DEPTH) {
            cx = caller_cx(caller_level, NULL);
            if (!cx || CxTYPE(cx) != CXt_EVAL || !CxREALEVAL(cx)) {
                break;
            }

            /* Now that we're in a string eval ("a real eval'), file name
             * becomes '(eval 1234)' and the line numbers get reset. So in order
             * to keep things sensible, we need to combine the eval line
             * picture with the 'real' line picture, and ignore the 'eval'
             * filename.
             */
            file = CopFILE(cx->blk_oldcop);
            caller_line = CopLINE(cx->blk_oldcop);
            /* 'eval' lines are 1 indexed, so each additional eval introduces
             * another line of drift: -1 per eval encountered corrects the
             * drift.
             */
            line = line + caller_line - 1;
            caller_level++;
        }
        TRACE(("PROBE check [%s] [%d]\n", file, line));
        if (!probe_lookup(aTHX_ file, line, PROBE_ACTION_LOOKUP)) {
            break;
        }

        settings = probe_settings(aTHX_ file, line);
        if (!settings) {
            break;
        }

        type = SvIV(*(av_fetch(settings, PROBE_SETTINGS_TYPE_INDEX, 0)));
        if (av_top_index(settings) == PROBE_SETTINGS_ARGS_INDEX) {
            user_callback_arg = *(av_fetch(settings, PROBE_SETTINGS_ARGS_INDEX, 0));
        }

        INFO(("PROBE triggered [%s] [%d] [%d]\n", file, line, type));
        if (probe_trigger_cb) {
            probe_invoke_callback(aTHX_ file, line, user_callback_arg, probe_trigger_cb);
        }

        if (type == PROBE_TYPE_ONCE) {
            probe_lookup(aTHX_ file, line, PROBE_ACTION_REMOVE);
        }
    } while (0);

    return ret;
}

static void probe_enable(void)
{
    if (probe_is_enabled()) {
        return;
    }
    INFO(("PROBE enabling\n"));
    probe_enabled = 1;
}

static void probe_clear(pTHX)
{
    if (probe_hash) {
        hv_clear(probe_hash);
    } else {
        probe_hash = newHV();
    }
    INFO(("PROBE cleared\n"));
}

static void probe_reset(pTHX_ int installed)
{
    probe_installed = installed;
    probe_enabled = 0;
    probe_clear(aTHX);
    if (probe_trigger_cb) {
        SvREFCNT_dec(probe_trigger_cb);
    }
    probe_trigger_cb = 0;
}

static void probe_disable(void)
{
    if (!probe_is_enabled()) {
        return;
    }
    probe_enabled = 0;
    INFO(("PROBE disabled\n"));
}

static int probe_is_installed(void)
{
    return probe_installed;
}

static void probe_install(pTHX)
{
    if (probe_is_installed()) {
        return;
    }

    INFO(("PROBE installed, [%p] => [%p]\n", PL_ppaddr[OP_NEXTSTATE], probe_nextstate));

    if (!probe_nextstate_orig) {
        probe_nextstate_orig = PL_ppaddr[OP_NEXTSTATE];
    }
    PL_ppaddr[OP_NEXTSTATE] = probe_nextstate;
    probe_reset(aTHX_ 1);
    probe_clear(aTHX);
}

static void probe_remove(pTHX)
{
    if (!probe_is_installed()) {
        return;
    }
    INFO(("PROBE removed, [%p] => [%p]\n", PL_ppaddr[OP_NEXTSTATE], probe_nextstate_orig));
    if (probe_nextstate_orig) {
        PL_ppaddr[OP_NEXTSTATE] = probe_nextstate_orig;
    }
    probe_reset(aTHX_ 0);
}

MODULE = Devel::Probe        PACKAGE = Devel::Probe
PROTOTYPES: DISABLE

#################################################################

void
install()
CODE:
    probe_install(aTHX);

void
remove()
CODE:
    probe_remove(aTHX);

int
is_installed()
CODE:
    RETVAL = probe_is_installed();
OUTPUT: RETVAL

void
enable()
CODE:
    probe_enable();

void
disable()
CODE:
    probe_disable();

int
is_enabled()
CODE:
    RETVAL = probe_is_enabled();
OUTPUT: RETVAL

void
clear()
CODE:
    probe_disable();
    probe_clear(aTHX);

HV *
_internal_probe_state()
CODE:
    RETVAL = probe_hash;
OUTPUT: RETVAL

void
trigger(SV* callback)
CODE:
    if (probe_trigger_cb == (SV*)NULL) {
        probe_trigger_cb = newSVsv(callback);
    } else {
        SvSetSV(probe_trigger_cb, callback);
    }
