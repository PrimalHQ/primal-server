#include "postgres.h"

#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"
#include "utils/numeric.h"
#include "utils/jsonb.h"
#include "lib/stringinfo.h"
#include "funcapi.h"
#include "pgstat.h"

#include "storage/ipc.h"

#include <julia.h>

#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <error.h>
#include <stdlib.h>

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(execq);

Datum
execq(PG_FUNCTION_ARGS)
{
    char *command;
    int cnt;
    int ret;
    uint64 proc;

    /* Convert given text object to a C string */
    command = text_to_cstring(PG_GETARG_TEXT_PP(0));
    cnt = PG_GETARG_INT32(1);

    SPI_connect();

    ret = SPI_exec(command, cnt);

    proc = SPI_processed;

    /*
     * If some rows were fetched, print them via elog(INFO).
     */
    if (ret > 0 && SPI_tuptable != NULL)
    {
        SPITupleTable *tuptable = SPI_tuptable;
        TupleDesc tupdesc = tuptable->tupdesc;
        char buf[8192];
        uint64 j;

        for (j = 0; j < tuptable->numvals; j++)
        {
            HeapTuple tuple = tuptable->vals[j];
            int i;

            for (i = 1, buf[0] = 0; i <= tupdesc->natts; i++)
                snprintf(buf + strlen(buf), sizeof(buf) - strlen(buf), " %s%s",
                        SPI_getvalue(tuple, tupdesc, i),
                        (i == tupdesc->natts) ? " " : " |");
            elog(INFO, "EXECQ: %s", buf);
        }
    }

    SPI_finish();
    /* pfree(command); */

    PG_RETURN_INT64(proc);
}

PG_FUNCTION_INFO_V1(bench1);

Datum
bench1(PG_FUNCTION_ARGS)
{
    char *command;
    int cnt;
    int ret;
    uint64 proc;

    command = text_to_cstring(PG_GETARG_TEXT_PP(0));
    cnt = PG_GETARG_INT32(1);

    SPI_connect();

    SPIPlanPtr plan = SPI_prepare(command, 0, NULL);

    for (int i = 0; i < 10000; i++) {
        ret = SPI_execute_plan(plan, NULL, NULL, true, cnt);
    }

    proc = SPI_processed;

    /*
     * If some rows were fetched, print them via elog(INFO).
     */
    if (ret > 0 && SPI_tuptable != NULL)
    {
        SPITupleTable *tuptable = SPI_tuptable;
        TupleDesc tupdesc = tuptable->tupdesc;
        char buf[8192];
        uint64 j;

        for (j = 0; j < tuptable->numvals; j++)
        {
            HeapTuple tuple = tuptable->vals[j];
            int i;

            for (i = 1, buf[0] = 0; i <= tupdesc->natts; i++)
                snprintf(buf + strlen(buf), sizeof(buf) - strlen(buf), " %s%s",
                        SPI_getvalue(tuple, tupdesc, i),
                        (i == tupdesc->natts) ? " " : " |");
            elog(INFO, "EXECQ: %s", buf);
        }
    }

    SPI_finish();
    /* pfree(command); */

    PG_RETURN_INT64(proc);
}


/* JULIA_DEFINE_FAST_TLS // only define this once, in an executable (not in a shared library) if you want fast code. */

/* NOINLINE static void record_backtrace(jl_ptls_t ptls, int skip) JL_NOTSAFEPOINT; */

static void p_sigsegv_handler(int sig, siginfo_t *si, void *unused)
{
    printf("%d: got SIGSEGV at address: 0x%lx\n", getpid(), (long)si->si_addr);
    /* jl_task_t *ct = jl_get_current_task(); */
    /* if (ct) { */
    /*     record_backtrace(ct->ptls, 1); */
    /*     jl_print_backtrace(); */
    /* } */
    /* jl_print_backtrace(); */

    if (pgStatSessionEndCause == DISCONNECT_NORMAL)
        pgStatSessionEndCause = DISCONNECT_FATAL;

    proc_exit(1);
    exit(1);
}

PG_FUNCTION_INFO_V1(p_julia_init);

jl_value_t* p_missing = NULL;
jl_value_t* p_convert_pg_to_jl = NULL;
jl_value_t* p_api_call = NULL;

Datum
p_julia_init(PG_FUNCTION_ARGS)
{
    char* code_root = getenv("PRIMALSERVER_CODE_ROOT");
    if (!code_root) {
        elog(ERROR, "p_julia_init: PRIMALSERVER_CODE_ROOT env var is not set");
        PG_RETURN_INT64(0);
    }

    if (!jl_is_initialized()) {
        struct sigaction sa;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        sa.sa_sigaction = p_sigsegv_handler;
        if (sigaction(SIGSEGV, &sa, NULL) == -1) {
            perror("sigaction for SIGSEGV");
        }

        jl_options.handle_signals = JL_OPTIONS_HANDLE_SIGNALS_OFF;
        char fn[500];
        sprintf(&fn[0], "/tmp/pg-primal-ext-precompile-%d.jl", getpid());
        jl_options.trace_compile = strdup(&fn[0]);
        printf("julia: writing compilation trace to %s\n", jl_options.trace_compile);
        jl_init();
    }

    char init_code[2000];
    sprintf(&init_code[0], "try Main.include(\"%s/primal-server/pg_ext_init.jl\") catch ex println(ex) end", code_root);

    jl_eval_string(&init_code[0]);

    if (NULL == (p_missing = jl_get_function(jl_base_module, "missing"))) {
        elog(ERROR, "p_julia_init: !p_missing");
    }
    if (NULL == (p_convert_pg_to_jl = jl_get_function(jl_main_module, "p_convert_pg_to_jl"))) {
        elog(ERROR, "p_julia_init: !p_convert_pg_to_jl");
    }
    if (NULL == (p_api_call = jl_get_function(jl_main_module, "p_api_call"))) {
        elog(ERROR, "p_julia_init: !p_api_call");
    }

    /* jl_gc_enable(0); */

    PG_RETURN_INT64(0);
}

PG_FUNCTION_INFO_V1(p_julia_done);

Datum
p_julia_done(PG_FUNCTION_ARGS)
{
    if (jl_is_initialized()) {
        jl_atexit_hook(0);
    }

    PG_RETURN_INT64(0);
}

PG_FUNCTION_INFO_V1(p_julia_eval);

Datum
p_julia_eval(PG_FUNCTION_ARGS)
{
    if (!jl_is_initialized()) {
        elog(ERROR, "p_julia_eval: julia is not initialized");
        PG_RETURN_TEXT_P(cstring_to_text(""));
    }

    text *rettext = NULL;

    char *code = text_to_cstring(PG_GETARG_TEXT_PP(0));
    jl_value_t *ret = jl_eval_string(code);
    /* pfree(code); */

    if (ret != NULL && jl_is_string(ret)) {
        rettext = cstring_to_text_with_len(jl_string_data(ret), jl_string_len(ret));
    }

    if (rettext == NULL) {
        PG_RETURN_NULL();
    } else {
        PG_RETURN_TEXT_P(rettext);
    }
}

ReturnSetInfo* g_rsinfo = NULL;
void p_push_result_record(Datum* values, bool* nulls)
{
    if (g_rsinfo) {
        tuplestore_putvalues(g_rsinfo->setResult, g_rsinfo->setDesc, values, nulls);
    }
}

PG_FUNCTION_INFO_V1(p_julia_api_call);

Datum
p_julia_api_call(PG_FUNCTION_ARGS)
{
    if (!jl_is_initialized()) {
        elog(ERROR, "p_julia_api_call: julia is not initialized");
        PG_RETURN_NULL();
    }
    if (!p_api_call) {
        elog(ERROR, "p_api_call: not initialized");
        PG_RETURN_NULL();
    }

    g_rsinfo = (ReturnSetInfo*)fcinfo->resultinfo;

    InitMaterializedSRF(fcinfo, 0);

    char *request = text_to_cstring(PG_GETARG_TEXT_PP(0));
    jl_call1(p_api_call, jl_cstr_to_string(request));
    /* pfree(request); */

    g_rsinfo = NULL;

    PG_RETURN_VOID();
}

jl_value_t* p_collect_results()
{
    jl_value_t* vv = NULL;
    jl_value_t* array_type = NULL;
    jl_array_t* colnames = NULL;
    jl_array_t* rows = NULL;
    jl_tupletype_t* tt = NULL;

    JL_GC_PUSH4(&array_type, &colnames, &rows, &tt);

    array_type = jl_apply_array_type((jl_value_t*)jl_any_type, 1);

    colnames = jl_alloc_array_1d(array_type, 0);
    rows = jl_alloc_array_1d(array_type, 0);

    jl_value_t* types[2] = {
        (jl_value_t*)array_type,
        (jl_value_t*)array_type,
    };
    tt = jl_apply_tuple_type_v(types, 2);

    if (SPI_tuptable != NULL) {
        SPITupleTable *tuptable = SPI_tuptable;
        TupleDesc tupdesc = tuptable->tupdesc;

        for (int i = 1; i <= tupdesc->natts; i++) {
            char* colname = SPI_fname(tupdesc, i);
            jl_array_ptr_1d_push(colnames, jl_cstr_to_string(colname));
            /* pfree(colname); */
        }

        for (int j = 0; j < tuptable->numvals; j++) {
            jl_array_t* cols = jl_alloc_array_1d(array_type, 0);
            jl_array_ptr_1d_push(rows, (jl_value_t*)cols);

            HeapTuple tuple = tuptable->vals[j];
            for (int i = 1; i <= tupdesc->natts; i++) {
                bool isnull = false;
                Oid oid = SPI_gettypeid(tupdesc, i);
                /* printf("p_collect_results | column: %d  oid: %d\n", i, oid); */
                switch (oid) {
                    #define SPI_BIN_VAL \
                        Datum d = SPI_getbinval(tuple, tupdesc, i, &isnull); \
                        if (isnull) { \
                            jl_array_ptr_1d_push(cols, jl_nothing); \
                        } else

                    case 16: // bool
                        {
                            SPI_BIN_VAL
                            {
                                jl_array_ptr_1d_push(cols, jl_box_bool(DatumGetBool(d)));
                            }
                        }
                        break;
                    case 17: // bytea
                        {
                            SPI_BIN_VAL
                            {
                                bytea* r = DatumGetByteaP(d);
                                if (r) {
                                    jl_array_ptr_1d_push(cols, (jl_value_t*)jl_pchar_to_array(VARDATA_ANY(r), VARSIZE_ANY_EXHDR(r)));
                                    /* pfree(r); */
                                }
                            }
                        }
                        break;
                    case 20: // int8
                        {
                            SPI_BIN_VAL
                            {
                                jl_array_ptr_1d_push(cols, jl_box_int64(DatumGetInt64(d)));
                            }
                        }
                        break;
                    case 23: // int4
                        {
                            SPI_BIN_VAL
                            {
                                jl_array_ptr_1d_push(cols, jl_box_int32(DatumGetInt32(d)));
                            }
                        }
                        break;
                    case 25: // text
                        {
                            SPI_BIN_VAL
                            {
                                text* r = DatumGetTextP(d);
                                /* printf("r: %p\n", r); */
                                if (r) {
                                    jl_array_ptr_1d_push(cols, (jl_value_t*)jl_pchar_to_string(VARDATA_ANY(r), VARSIZE_ANY_EXHDR(r)));
                                    /* pfree(r); */
                                }
                            }
                        }
                        break;
                    case 700: // float4
                        {
                            SPI_BIN_VAL
                            {
                                jl_array_ptr_1d_push(cols, jl_box_float32(DatumGetFloat4(d)));
                            }
                        }
                        break;
                    case 701: // float8
                        {
                            SPI_BIN_VAL
                            {
                                jl_array_ptr_1d_push(cols, jl_box_float64(DatumGetFloat8(d)));
                            }
                        }
                        break;
                    case 1043: // varchar
                        {
                            SPI_BIN_VAL
                            {
                                VarChar* r = DatumGetVarCharP(d);
                                if (r) {
                                    jl_array_ptr_1d_push(cols, (jl_value_t*)jl_pchar_to_string(VARDATA_ANY(r), VARSIZE_ANY_EXHDR(r)));
                                    /* pfree(r); */
                                }
                            }
                        }
                        break;
                    case 1114: // timestamp
                        {
                            SPI_BIN_VAL
                            {
                                Timestamp r = DatumGetTimestamp(d);
                                jl_array_ptr_1d_push(cols, jl_call2(p_convert_pg_to_jl, jl_box_int64(oid), jl_box_int64(r)));
                            }
                        }
                        break;
                    case 1700: // numeric
                        {
                            SPI_BIN_VAL
                            {
                                Numeric r = DatumGetNumeric(d);
                                if (r) {
                                    jl_array_ptr_1d_push(cols, jl_call2(p_convert_pg_to_jl, jl_box_int64(oid), jl_cstr_to_string(numeric_normalize(r))));
                                    /* pfree(r); */
                                }
                            }
                        }
                        break;
                    default:
                        {
                            char* s = SPI_getvalue(tuple, tupdesc, i);
                            if (s) {
                                jl_array_ptr_1d_push(cols, jl_call2(p_convert_pg_to_jl, jl_box_int64(oid), jl_cstr_to_string(s)));
                                /* pfree(s); */
                            } else {
                                jl_array_ptr_1d_push(cols, jl_nothing);
                            }
                        }
                        break;
                }
            }
        }
    }

    jl_value_t* tup_values[2] = {
        (jl_value_t*)colnames,
        (jl_value_t*)rows,
    };

    jl_value_t *tuple = jl_new_structv(tt, tup_values, 2);

    JL_GC_POP();

    return tuple;
}

Datum p_bytes_to_varlena_datum(const char* data, int len)
{
    size_t size = len + VARHDRSZ;
    bytea  *result = palloc(size);

    SET_VARSIZE(result, size);
    memcpy(VARDATA(result), data, len);
    return PointerGetDatum(result);
}

/* PG_FUNCTION_INFO_V1(ttt1); */
/* PG_FUNCTION_INFO_V1(ttt2); */

#if 0
Datum
ttt1(PG_FUNCTION_ARGS)
{
    for (int k = 0; k < 1000000; k++) {
        if (k % 10000 == 0) printf("k: %d\n", k);

        SPI_connect();

        int ret = SPI_exec("select '111'::jsonb", 10);

        if (ret > 0 && SPI_tuptable != NULL)
        {
            SPITupleTable *tuptable = SPI_tuptable;
            TupleDesc tupdesc = tuptable->tupdesc;

            for (uint64 j = 0; j < tuptable->numvals; j++)
            {
                HeapTuple tuple = tuptable->vals[j];
                bool isnull;
                Datum d = SPI_getbinval(tuple, tupdesc, 1, &isnull);
                Jsonb* jb = DatumGetJsonbP(d);
                /* printf("jb: %p\n", jb); */
                if (jb) {
                    StringInfo jtext = makeStringInfo();
                    (void) JsonbToCString(jtext, &jb->root, VARSIZE(jb));
                    /* printf("data: %p len: %d\n", jtext->data, jtext->len); */
                    pfree(jtext->data);
                    pfree(jtext);
                    pfree(jb);
                }
            }
        }

        SPI_finish();
    }

    PG_RETURN_INT64(0);
}
#endif

#if 0
Datum
ttt1(PG_FUNCTION_ARGS)
{
    /* printf("sizeof(Oid) = %ld\n", sizeof(Oid)); */
    SPI_connect();
    Oid argtypes[] = { 20, 20, };
    SPIPlanPtr plan1 = SPI_prepare("select $1 + $2", 2, &argtypes[0]);
    printf("ret: %p\n", plan1);
    SPI_finish();
    PG_RETURN_INT64(0);
}
#endif

#if 0
Datum
ttt2(PG_FUNCTION_ARGS)
{
    ReturnSetInfo* rsinfo = (ReturnSetInfo*)fcinfo->resultinfo;

    InitMaterializedSRF(fcinfo, 0);

    Datum values[3] = {0};
    bool nulls[3] = {0};

    values[0] = Int64GetDatum(100);
    values[1] = Int64GetDatum(101);
    values[2] = Int64GetDatum(102);
    tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

    values[0] = Int64GetDatum(200);
    values[1] = Int64GetDatum(201);
    values[2] = Int64GetDatum(202);
    tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

    PG_RETURN_VOID();
}
#endif

