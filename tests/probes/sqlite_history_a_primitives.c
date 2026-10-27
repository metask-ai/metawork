/* Stage A only: canonical SQLite primitives, not a production Storage API.
 * No custom VFS. All files belong to the runner's isolated directory. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"primitive assertion line=%d\n",__LINE__); return 1; } } while(0)
static double ms(void) { LARGE_INTEGER n,f; QueryPerformanceCounter(&n); QueryPerformanceFrequency(&f); return (double)n.QuadPart*1000.0/(double)f.QuadPart; }
static int exec(sqlite3 *db,const char *s) { int r=sqlite3_exec(db,s,0,0,0); if(r!=SQLITE_OK) fprintf(stderr,"sqlite rc=%d\n",r); return r; }
static sqlite3_int64 integer(sqlite3 *db,const char *s) {
    sqlite3_stmt *q=0; sqlite3_int64 v=-1;
    if(sqlite3_prepare_v2(db,s,-1,&q,0)==SQLITE_OK && sqlite3_step(q)==SQLITE_ROW) v=sqlite3_column_int64(q,0);
    sqlite3_finalize(q); return v;
}
static sqlite3 *open_db(const char *path) {
    sqlite3 *db=0;
    if(sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,0)!=SQLITE_OK) return 0;
    sqlite3_extended_result_codes(db,1);
    if(exec(db,"PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;PRAGMA mmap_size=0;PRAGMA foreign_keys=ON;PRAGMA secure_delete=ON;PRAGMA busy_timeout=250;")!=SQLITE_OK) return 0;
    sqlite3_limit(db,SQLITE_LIMIT_LENGTH,8*1024*1024);
    sqlite3_limit(db,SQLITE_LIMIT_VARIABLE_NUMBER,64);
    sqlite3_limit(db,SQLITE_LIMIT_ATTACHED,0);
    return db;
}
static unsigned long long size(const char *p) {
    WIN32_FILE_ATTRIBUTE_DATA a;
    if(!GetFileAttributesExA(p,GetFileExInfoStandard,&a)) return 0;
    return ((unsigned long long)a.nFileSizeHigh<<32)|a.nFileSizeLow;
}
/* Windows shared read, used solely to search disposable test bytes. No values logged. */
static int contains(const char *p,const char *needle) {
    HANDLE f=CreateFileA(p,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if(f==INVALID_HANDLE_VALUE) return GetLastError()==ERROR_FILE_NOT_FOUND?0:-1;
    unsigned long long n=size(p); if(n>256ULL*1024*1024) { CloseHandle(f); return -1; }
    char *b=(char*)malloc((size_t)n+1); DWORD read=0;
    if(!b || !ReadFile(f,b,(DWORD)n,&read,0) || read!=n) { free(b);CloseHandle(f);return -1; }
    size_t len=strlen(needle); int hit=0;
    for(size_t i=0;i+len<=read;i++) if(memcmp(b+i,needle,len)==0) { hit=1;break; }
    free(b);CloseHandle(f);return hit;
}
static int checkpoint(sqlite3 *db,int *log,int *done,double *duration) {
    double t=ms(); int r=sqlite3_wal_checkpoint_v2(db,"main",SQLITE_CHECKPOINT_TRUNCATE,log,done); *duration=ms()-t; return r;
}
static const char marker[]="stage-a-disposable-credential-6e716c362e38468f";
static int child(const char *path) {
    sqlite3 *db=open_db(path); CHECK(db);
    CHECK(exec(db,"BEGIN IMMEDIATE;UPDATE witness SET generation=777;COMMIT;")==SQLITE_OK);
    /* COMMIT/FULL returned; lose the acknowledgment and every destructor. */
    TerminateProcess(GetCurrentProcess(),73); return 1;
}
int stage_a_primitives(void) {
    const char *base=getenv("METAWORK_SQLITE_A_DIR"); CHECK(base);
    char path[32768],wal[32768],shm[32768];
    CHECK(snprintf(path,sizeof(path),"%s/primitives.sqlite",base)>0);
    snprintf(wal,sizeof(wal),"%s-wal",path);snprintf(shm,sizeof(shm),"%s-shm",path);
    const char *mode=getenv("METAWORK_SQLITE_A_MODE");
    if(mode && strcmp(mode,"child")==0) return child(path);
    sqlite3 *db=open_db(path); CHECK(db);
    CHECK(integer(db,"PRAGMA synchronous")==2 && integer(db,"PRAGMA secure_delete")==1);
    CHECK(exec(db,"CREATE TABLE witness(generation INTEGER);INSERT INTO witness VALUES(0);CREATE TABLE secrets(id INTEGER PRIMARY KEY,b BLOB);CREATE TABLE bound_value(b BLOB);")==SQLITE_OK);
    int log=-1,done=-1;double duration=0;
    CHECK(checkpoint(db,&log,&done,&duration)==SQLITE_OK && log==0 && done==0);
    sqlite3 *reader=open_db(path); CHECK(reader);
    CHECK(exec(reader,"BEGIN;")==SQLITE_OK && integer(reader,"SELECT generation FROM witness")==0);
    char exe[32768],command[32770];CHECK(GetModuleFileNameA(0,exe,sizeof(exe))>0);
    snprintf(command,sizeof(command),"\"%s\"",exe);
    STARTUPINFOA si;PROCESS_INFORMATION pi;ZeroMemory(&si,sizeof(si));si.cb=sizeof(si);ZeroMemory(&pi,sizeof(pi));
    CHECK(SetEnvironmentVariableA("METAWORK_SQLITE_A_MODE","child"));
    CHECK(CreateProcessA(0,command,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&pi));
    CHECK(SetEnvironmentVariableA("METAWORK_SQLITE_A_MODE",0));
    CHECK(WaitForSingleObject(pi.hProcess,30000)==WAIT_OBJECT_0);
    DWORD exit_code=0;CHECK(GetExitCodeProcess(pi.hProcess,&exit_code));CloseHandle(pi.hThread);CloseHandle(pi.hProcess);CHECK(exit_code==73);
    CHECK(integer(db,"SELECT generation FROM witness")==777);
    int busy=checkpoint(db,&log,&done,&duration);CHECK(busy==SQLITE_BUSY && size(wal)>0);
    printf("A_PRIMITIVE {\"kind\":\"readable_witness_busy_sync\",\"witness\":777,\"checkpoint_rc\":%d,\"log\":%d,\"done\":%d,\"ms\":%.6f,\"wal_bytes\":%llu,\"must_remain_unknown\":true}\n",busy,log,done,duration,size(wal));
    CHECK(exec(reader,"ROLLBACK;")==SQLITE_OK);CHECK(sqlite3_close(reader)==SQLITE_OK);
    CHECK(checkpoint(db,&log,&done,&duration)==SQLITE_OK && log==0 && done==0 && size(wal)==0);
    CHECK(integer(db,"SELECT generation FROM witness")==777);
    printf("A_PRIMITIVE {\"kind\":\"confirmed_checkpoint\",\"ms\":%.6f,\"log\":%d,\"done\":%d,\"wal_bytes\":%llu}\n",duration,log,done,size(wal));
    /* Actual engine value/row limit, including SQLite row overhead. */
    for(int n=7*1024*1024;n<=8*1024*1024+1;n+=(n==7*1024*1024?1024*1024:1)) {
        sqlite3_stmt *s=0;CHECK(sqlite3_prepare_v2(db,"INSERT INTO bound_value VALUES(zeroblob(?))",-1,&s,0)==SQLITE_OK);
        sqlite3_bind_int(s,1,n);int r=sqlite3_step(s);sqlite3_finalize(s);
        CHECK((n<8*1024*1024 && r==SQLITE_DONE)||(n>=8*1024*1024 && r==SQLITE_TOOBIG));
        printf("A_PRIMITIVE {\"kind\":\"length_limit\",\"payload_bytes\":%d,\"rc\":%d}\n",n,r);
    }
    CHECK(exec(db,"DELETE FROM bound_value;")==SQLITE_OK);
    sqlite3_stmt *insert=0;CHECK(sqlite3_prepare_v2(db,"INSERT INTO secrets VALUES(1,?)",-1,&insert,0)==SQLITE_OK);
    size_t n=512*1024;char *body=(char*)malloc(n);CHECK(body);memset(body,'x',n);memcpy(body+2000,marker,strlen(marker));
    CHECK(sqlite3_bind_blob(insert,1,body,(int)n,SQLITE_TRANSIENT)==SQLITE_OK && sqlite3_step(insert)==SQLITE_DONE);sqlite3_finalize(insert);free(body);
    CHECK(checkpoint(db,&log,&done,&duration)==SQLITE_OK);
    CHECK(contains(path,marker)==1);
    reader=open_db(path);CHECK(reader);CHECK(exec(reader,"BEGIN;")==SQLITE_OK && integer(reader,"SELECT length(b) FROM secrets")==512*1024);
    CHECK(sqlite3_prepare_v2(db,"INSERT INTO secrets VALUES(2,?)",-1,&insert,0)==SQLITE_OK);
    CHECK(sqlite3_bind_blob(insert,1,marker,(int)strlen(marker),SQLITE_STATIC)==SQLITE_OK && sqlite3_step(insert)==SQLITE_DONE);sqlite3_finalize(insert);
    CHECK(exec(db,"UPDATE secrets SET b=zeroblob(524288);")==SQLITE_OK);
    CHECK(contains(path,marker)==1 && contains(wal,marker)==1);
    CHECK(checkpoint(db,&log,&done,&duration)==SQLITE_BUSY);
    CHECK(exec(reader,"ROLLBACK;")==SQLITE_OK && sqlite3_close(reader)==SQLITE_OK);
    CHECK(checkpoint(db,&log,&done,&duration)==SQLITE_OK && log==0 && done==0);
    CHECK(sqlite3_close(db)==SQLITE_OK);
    CHECK(contains(path,marker)==0 && contains(wal,marker)==0 && contains(shm,marker)==0);
    printf("A_PRIMITIVE {\"kind\":\"credential_cleanup\",\"secure_delete\":1,\"blocked_reader_observed\":true,\"old_db_and_wal_plaintext_observed\":true,\"managed_plaintext_remaining\":false,\"final_checkpoint_ms\":%.6f}\n",duration);
    /* Closed DB publication, same-volume durable move. No user files involved. */
    char published[32768];snprintf(published,sizeof(published),"%s/published.sqlite",base);
    CHECK(size(wal)==0 && size(shm)==0);
    double publish=ms();CHECK(MoveFileExA(path,published,MOVEFILE_WRITE_THROUGH));publish=ms()-publish;
    db=open_db(published);CHECK(db);CHECK(integer(db,"SELECT generation FROM witness")==777);
    /* integrity_check returns text, checked explicitly rather than via integer(). */
    sqlite3_stmt *integrity=0;CHECK(sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&integrity,0)==SQLITE_OK);CHECK(sqlite3_step(integrity)==SQLITE_ROW && strcmp((const char*)sqlite3_column_text(integrity,0),"ok")==0);sqlite3_finalize(integrity);
    CHECK(sqlite3_close(db)==SQLITE_OK);
    printf("A_PRIMITIVE {\"kind\":\"closed_publish\",\"rename_ms\":%.6f,\"witness\":777,\"integrity\":\"ok\",\"power_loss_proven\":false}\n",publish);
    printf("A_PRIMITIVE {\"kind\":\"engine\",\"version\":\"%s\",\"source_id\":\"%s\",\"threadsafe\":%d}\n",sqlite3_libversion(),sqlite3_sourceid(),sqlite3_threadsafe());
    fflush(stdout);return 0;
}
