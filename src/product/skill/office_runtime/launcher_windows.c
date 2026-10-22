#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>

/* Standalone Office calls own this non-inheritable job handle. Keeping it
 * armed until process teardown also covers TerminateProcess on this entrypoint.
 * This is an Office component executable, not a Host process service. */
static HANDLE office_job;
static wchar_t command[32768];
static size_t used;
static HANDLE scope[32];
static DWORD scope_count;
static wchar_t version_job_name[64];

/* Installed resources bind to the Primary Host that published their Skill
 * source. This is process identity, never a Task/Session/version reference.
 * Only ancestors through that exact process are observed; Explorer, terminals
 * and other ancestors above the Host do not own a running Office operation. */
static int bind_shell_scope(const wchar_t *component) {
    wchar_t path[32768];
    if (wcslen(component) >= 32700) return 0;
    wmemcpy(path, component, wcslen(component) + 1);
    wchar_t *version = wcsrchr(path, L'\\');
    if (!version || wcslen(version + 1) != 32) return 1; /* explicit dev tree */
    for (wchar_t *c = version + 1; *c; ++c)
        if (!((*c >= L'0' && *c <= L'9') || (*c >= L'a' && *c <= L'f') ||
              (*c >= L'A' && *c <= L'F'))) return 1;
    *version = 0;
    wchar_t *versions = wcsrchr(path, L'\\');
    if (!versions || _wcsicmp(versions + 1, L"versions")) return 1;
    wchar_t identity[33];
    const wchar_t *id = wcsrchr(component, L'\\') + 1;
    for (size_t i = 0; i < 32; ++i)
        identity[i] = id[i] >= L'A' && id[i] <= L'F' ? id[i] + (L'a' - L'A') : id[i];
    identity[32] = 0;
    if (swprintf(version_job_name, 64, L"Local\\MetaWork.Office.Version.%ls", identity) < 0) return 0;
    wmemcpy(versions + 1, L"host.scope", 11);
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    unsigned char record[24] = {0};
    DWORD read = 0;
    BY_HANDLE_FILE_INFORMATION info;
    int valid = GetFileInformationByHandle(file, &info) &&
        !(info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
        info.nFileSizeHigh == 0 && info.nFileSizeLow == sizeof(record) &&
        ReadFile(file, record, sizeof(record), &read, NULL) && read == sizeof(record) &&
        !memcmp(record, "MWOFS001", 8);
    CloseHandle(file);
    uint32_t host_pid = 0, reserved = 1;
    uint64_t host_birth = 0;
    memcpy(&host_pid, record + 8, sizeof(host_pid));
    memcpy(&reserved, record + 12, sizeof(reserved));
    memcpy(&host_birth, record + 16, sizeof(host_birth));
    if (!valid || !host_pid || reserved || !host_birth) return 0;
    FILETIME child_birth, exited, kernel, user;
    if (!GetProcessTimes(GetCurrentProcess(), &child_birth, &exited, &kernel, &user)) return 0;
    DWORD child_pid = GetCurrentProcessId();
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 0;
    int bound = 0;
    for (DWORD depth = 0; depth < 32; ++depth) {
        PROCESSENTRY32W entry = {0};
        entry.dwSize = sizeof(entry);
        DWORD parent = 0;
        if (Process32FirstW(snapshot, &entry)) do {
            if (entry.th32ProcessID == child_pid) { parent = entry.th32ParentProcessID; break; }
        } while (Process32NextW(snapshot, &entry));
        if (!parent || parent == child_pid) break;
        HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, parent);
        if (!handle) break;
        FILETIME birth;
        if (!GetProcessTimes(handle, &birth, &exited, &kernel, &user) ||
            CompareFileTime(&birth, &child_birth) > 0 || WaitForSingleObject(handle, 0) != WAIT_TIMEOUT) {
            CloseHandle(handle);
            break;
        }
        scope[scope_count++] = handle;
        if (parent == host_pid) {
            uint64_t actual_birth;
            memcpy(&actual_birth, &birth, sizeof(actual_birth));
            bound = actual_birth == host_birth;
            break;
        }
        child_pid = parent;
        child_birth = birth;
    }
    CloseHandle(snapshot);
    return bound;
}

static int host_job_name(const wchar_t *name) {
    const wchar_t *prefix = L"Local\\MetaWork.Office.";
    size_t length = wcslen(prefix);
    const wchar_t *operation = L"Local\\MetaWork.Office.Op.";
    if (!wcsncmp(name, operation, wcslen(operation))) {
        prefix = operation;
        length = wcslen(prefix);
    }
    if (wcslen(name) != length + 32 || wcsncmp(name, prefix, length)) return 0;
    for (size_t i = length; i < length + 32; ++i)
        if (!((name[i] >= L'0' && name[i] <= L'9') ||
              (name[i] >= L'a' && name[i] <= L'f'))) return 0;
    return 1;
}

static int put(wchar_t value) {
    if (used + 1 >= sizeof(command) / sizeof(command[0])) return 0;
    command[used++] = value;
    return 1;
}

/* Encode one argument using the Windows CRT backslash/quote grammar. */
static int argument(const wchar_t *value) {
    if (used && !put(L' ')) return 0;
    if (!put(L'"')) return 0;
    size_t backslashes = 0;
    for (;;) {
        wchar_t c = *value++;
        if (c == L'\\') {
            ++backslashes;
            continue;
        }
        size_t count = (c == L'"' || c == 0) ? backslashes * 2 : backslashes;
        while (count--) if (!put(L'\\')) return 0;
        backslashes = 0;
        if (c == 0) break;
        if (c == L'"' && !put(L'\\')) return 0;
        if (!put(c)) return 0;
    }
    return put(L'"');
}

static int fail(const char *reason) {
    /* No document content, arguments or inherited environment in diagnostics. */
    fprintf(stderr, "Office launcher: %s (Windows error %lu)\n", reason, GetLastError());
    return 1;
}

int wmain(int argc, wchar_t **argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    wchar_t root[32768], python[32768], script[32768], program[32768];
    DWORD length = GetModuleFileNameW(NULL, root, 32768);
    if (!length || length >= 32768) return fail("cannot resolve component path");
    wchar_t *end = wcsrchr(root, L'\\');
    if (!end) return fail("invalid component executable path");
    *end = 0; /* bin */
    end = wcsrchr(root, L'\\');
    if (!end) return fail("invalid component root");
    *end = 0;
    if (swprintf(python, 32768, L"%ls\\python\\bin\\python.exe", root) < 0 ||
        swprintf(script, 32768, L"%ls\\tools\\office.py", root) < 0 ||
        swprintf(program, 32768, L"%ls\\engine\\program", root) < 0)
        return fail("component path is too long");
    if (GetFileAttributesW(python) == INVALID_FILE_ATTRIBUTES ||
        GetFileAttributesW(script) == INVALID_FILE_ATTRIBUTES)
        return fail("component payload is missing");

    /* DLL lookup changes apply only to this explicit Office invocation. */
    DWORD old_length = GetEnvironmentVariableW(L"PATH", NULL, 0);
    size_t capacity = wcslen(program) + old_length + 2;
    if (capacity > 32767) return fail("component DLL path is too long");
    wchar_t *search = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, capacity * sizeof(wchar_t));
    if (!search) return fail("cannot allocate component DLL path");
    size_t prefix = wcslen(program);
    wmemcpy(search, program, prefix + 1);
    search[prefix++] = L';';
    if (old_length && GetEnvironmentVariableW(L"PATH", search + prefix, old_length) >= old_length) {
        HeapFree(GetProcessHeap(), 0, search);
        return fail("inherited DLL path changed");
    }
    BOOL environment_ready = SetEnvironmentVariableW(L"PATH", search);
    HeapFree(GetProcessHeap(), 0, search);
    if (!environment_ready) return fail("cannot prepare component DLL path");

    int first_argument = 1;
    int hosted = argc > 1 && !wcscmp(argv[1], L"--host-job");
    if (hosted) {
        if (argc < 4 || !host_job_name(argv[2])) return fail("invalid Host job reference");
        first_argument = 3;
        office_job = OpenJobObjectW(JOB_OBJECT_ASSIGN_PROCESS | JOB_OBJECT_QUERY, FALSE, argv[2]);
        if (!office_job) return fail("Host Office job is unavailable");
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
        if (!QueryInformationJobObject(office_job, JobObjectExtendedLimitInformation,
                &limits, sizeof(limits), NULL) ||
            !(limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) ||
            (limits.BasicLimitInformation.LimitFlags &
                (JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_BREAKAWAY_OK | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK)) ||
            !AssignProcessToJobObject(office_job, GetCurrentProcess())) {
            CloseHandle(office_job);
            return fail("cannot join Host Office job");
        }
        /* The Host is the lifetime owner. No component process may keep the
         * job alive after the Host dies. Join before starting any child. */
        CloseHandle(office_job);
        office_job = NULL;
    } else {
        if (!bind_shell_scope(root)) return fail("Office Shell scope is unavailable");
        if (version_job_name[0]) {
            HANDLE version_job = OpenJobObjectW(JOB_OBJECT_ASSIGN_PROCESS | JOB_OBJECT_QUERY, FALSE, version_job_name);
            if (!version_job) return fail("Office version is not active");
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION version_limits = {0};
            int joined = QueryInformationJobObject(version_job, JobObjectExtendedLimitInformation,
                    &version_limits, sizeof(version_limits), NULL) &&
                (version_limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) &&
                !(version_limits.BasicLimitInformation.LimitFlags & (JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
                    JOB_OBJECT_LIMIT_BREAKAWAY_OK | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK)) &&
                AssignProcessToJobObject(version_job, GetCurrentProcess());
            CloseHandle(version_job);
            if (!joined) return fail("Office version is closing");
        }
        office_job = CreateJobObjectW(NULL, NULL);
        if (!office_job) return fail("cannot create Office job");
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
            JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        if (!SetInformationJobObject(office_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
            !AssignProcessToJobObject(office_job, GetCurrentProcess())) {
            CloseHandle(office_job);
            return fail("cannot own Office process tree");
        }
    }

    if (!argument(python) || !argument(L"-I") || !argument(L"-S") || !argument(L"-B") ||
        !argument(L"-X") || !argument(L"utf8") || !argument(script))
        return fail("component command exceeds capacity");
    for (int i = first_argument; i < argc; ++i)
        if (!argument(argv[i])) return fail("Office arguments exceed capacity");
    command[used] = 0;

    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION child = {0};
    if (scope_count && WaitForMultipleObjects(scope_count, scope, FALSE, 0) != WAIT_TIMEOUT)
        return fail("Office Shell scope ended before execution");
    if (!CreateProcessW(python, command, NULL, NULL, TRUE, CREATE_NO_WINDOW,
            NULL, NULL, &startup, &child))
        return fail("cannot start component Python");
    CloseHandle(child.hThread);
    HANDLE waiting[33];
    waiting[0] = child.hProcess;
    for (DWORD i = 0; i < scope_count; ++i) waiting[i + 1] = scope[i];
    if (WaitForMultipleObjects(scope_count + 1, waiting, FALSE, INFINITE) != WAIT_OBJECT_0) {
        CloseHandle(child.hProcess);
        /* Returning tears down the entry's sole Job handle, including its own
         * process and every descendant. No Python finally block is required. */
        return fail("Office Shell scope ended during execution");
    }
    DWORD exit_code = 1;
    BOOL exited = GetExitCodeProcess(child.hProcess, &exit_code);
    CloseHandle(child.hProcess);
    if (!exited) return fail("cannot observe component Python exit");
    /* Hosted calls are joined and checked by Application, which owns the only
     * long-lived job handle. The standalone Shell path checks its own job. */
    if (hosted) return (int)exit_code;
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = {0};
    ULONGLONG deadline = GetTickCount64() + 2000;
    for (;;) {
        if (!QueryInformationJobObject(office_job, JobObjectBasicAccountingInformation,
                &accounting, sizeof(accounting), NULL))
            return fail("cannot observe Office process tree");
        if (accounting.ActiveProcesses == 1) break;
        if (GetTickCount64() >= deadline) return fail("Office descendants did not settle");
        /* Process handles can signal just before job accounting is updated. */
        Sleep(1);
    }
    /* The OS closes office_job at exit. It is never inherited by children. */
    return (int)exit_code;
}
