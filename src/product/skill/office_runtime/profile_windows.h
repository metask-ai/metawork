/* Office-entry-owned profiles. LibreOffice's deployment backend cannot open
 * its long registry names under an arbitrary Task/install scratch directory.
 * Select this one namespace before execution, never retry in another TMP.
 * Durable records identify recoverable directories; named, kill-on-close Jobs
 * exclude cleanup while an invocation or any descendant can still use them. */
#include <shlobj.h>
#include <objbase.h>

static wchar_t profile_root[260], profile_path[260], profile_record[260];
static HANDLE profile_roots[3];
static HANDLE profile_owned_directory;
static int profile_registered;

static int profile_identity(const wchar_t *name, size_t length) {
    if (length != 32) return 0;
    for (size_t i = 0; i < length; ++i)
        if (!((name[i] >= L'0' && name[i] <= L'9') ||
              (name[i] >= L'a' && name[i] <= L'f'))) return 0;
    return 1;
}

static HANDLE profile_directory(const wchar_t *path, int create) {
    if (create && !CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
        return INVALID_HANDLE_VALUE;
    HANDLE h = CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h == INVALID_HANDLE_VALUE) return h;
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(h, &info) ||
        !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(h);
        return INVALID_HANDLE_VALUE;
    }
    return h;
}

/* Parent directory handles deny rename/delete. Each child is opened without
 * following a reparse point and deleted through that exact handle. Even a
 * replaced leaf cannot redirect recursion or a path-based recursive delete. */
static int profile_delete(const wchar_t *path, unsigned depth, unsigned *budget, HANDLE owned) {
    if (depth > 48 || !*budget) return 0;
    --*budget;
    HANDLE h = owned ? owned : CreateFileW(path, DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND;
    BY_HANDLE_FILE_INFORMATION info;
    int ok = GetFileInformationByHandle(h, &info);
    if (ok && (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        wchar_t *child = HeapAlloc(GetProcessHeap(), 0, 32768 * sizeof(wchar_t));
        if (!child) { CloseHandle(h); return 0; }
        size_t length = wcslen(path);
        if (length > 32000) { HeapFree(GetProcessHeap(), 0, child); CloseHandle(h); return 0; }
        swprintf(child, 32768, L"%ls\\*", path);
        WIN32_FIND_DATAW entry;
        HANDLE search = FindFirstFileW(child, &entry);
        if (search == INVALID_HANDLE_VALUE) ok = GetLastError() == ERROR_FILE_NOT_FOUND;
        else {
            do {
                if (!wcscmp(entry.cFileName, L".") || !wcscmp(entry.cFileName, L"..")) continue;
                if (swprintf(child, 32768, L"%ls\\%ls", path, entry.cFileName) < 0 ||
                    !profile_delete(child, depth + 1, budget, NULL)) { ok = 0; break; }
            } while (FindNextFileW(search, &entry));
            if (ok && GetLastError() != ERROR_NO_MORE_FILES) ok = 0;
            FindClose(search);
        }
        HeapFree(GetProcessHeap(), 0, child);
    }
    FILE_DISPOSITION_INFO disposition = { TRUE };
    if (ok) ok = SetFileInformationByHandle(h, FileDispositionInfo, &disposition, sizeof(disposition));
    CloseHandle(h);
    return ok;
}

static int profile_remove(const wchar_t *directory, const wchar_t *record, HANDLE owned) {
    unsigned budget = 16384;
    /* Extended syntax is confined to native cleanup, never passed to UNO. */
    wchar_t extended[300];
    if (swprintf(extended, 300, L"\\\\?\\%ls", directory) < 0 ||
        !profile_delete(extended, 0, &budget, owned)) return 0;
    return DeleteFileW(record) || GetLastError() == ERROR_FILE_NOT_FOUND;
}

static HANDLE profile_job(const wchar_t *identity, int reservation) {
    wchar_t name[80];
    if (swprintf(name, 80, L"Local\\MetaWork.Office.Profile.%ls", identity) < 0) return NULL;
    HANDLE h = CreateJobObjectW(NULL, name);
    if (!h) return NULL;
    if (GetLastError() == ERROR_ALREADY_EXISTS) { CloseHandle(h); SetLastError(ERROR_BUSY); return NULL; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (reservation) limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    if (!SetInformationJobObject(h, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        CloseHandle(h); return NULL;
    }
    return h;
}

static int profile_recover(void) {
    wchar_t pattern[300];
    swprintf(pattern, 300, L"%ls\\*", profile_root);
    WIN32_FIND_DATAW item;
    HANDLE search = FindFirstFileW(pattern, &item);
    if (search == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
    int ok = 1;
    unsigned count = 0;
    do {
        size_t length = wcslen(item.cFileName);
        int scope_record = length >= 6 && !wcscmp(item.cFileName + length - 6, L".scope");
        int temporary = length == 37 && !wcscmp(item.cFileName + 32, L".next") &&
            profile_identity(item.cFileName, 32);
        if (!scope_record && !temporary) continue; /* unregistered paths */
        if (++count > 128 || (scope_record &&
            (length != 38 || !profile_identity(item.cFileName, 32)))) { ok = 0; break; }
        wchar_t identity[33], record[300], directory[300];
        wmemcpy(identity, item.cFileName, 32); identity[32] = 0;
        HANDLE reservation = profile_job(identity, 1);
        if (!reservation) {
            if (GetLastError() == ERROR_BUSY) continue;
            ok = 0; break;
        }
        swprintf(record, 300, L"%ls\\%ls", profile_root, item.cFileName);
        swprintf(directory, 300, L"%ls\\%ls", profile_root, identity);
        if (temporary) {
            unsigned budget = 1;
            ok = !(item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
                profile_delete(record, 0, &budget, NULL);
            CloseHandle(reservation);
            if (!ok) break;
            continue;
        }
        HANDLE file = CreateFileW(record, GENERIC_READ, FILE_SHARE_READ,
            NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        unsigned char bytes[40]; DWORD read = 0;
        BY_HANDLE_FILE_INFORMATION info;
        ok = file != INVALID_HANDLE_VALUE && GetFileInformationByHandle(file, &info) &&
            !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
            info.nFileSizeHigh == 0 && info.nFileSizeLow == sizeof(bytes) &&
            ReadFile(file, bytes, sizeof(bytes), &read, NULL) && read == sizeof(bytes) &&
            !memcmp(bytes, "MWOFP001", 8);
        if (ok) for (size_t i = 0; i < 32; ++i)
            if (bytes[8 + i] != (unsigned char)identity[i]) { ok = 0; break; }
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        if (ok) ok = profile_remove(directory, record, NULL);
        CloseHandle(reservation);
        if (!ok) break;
    } while (FindNextFileW(search, &item));
    if (ok && GetLastError() != ERROR_NO_MORE_FILES) ok = 0;
    FindClose(search);
    return ok;
}

static int profile_begin(void) {
    /* Known Folder is selected independently of inherited Task TMP, APPDATA,
     * user profile environment and the component's installation location. */
    const GUID local_appdata = {0xF1B32785,0x6FBA,0x4FCF,{0x9D,0x55,0x7B,0x8E,0x7F,0x15,0x70,0x91}};
    PWSTR local = NULL;
    if (FAILED(SHGetKnownFolderPath(&local_appdata, KF_FLAG_DONT_VERIFY, NULL, &local))) return 0;
    size_t base = wcslen(local);
    /* Reserve room for the engine's fixed registry suffixes. A genuinely
     * overlong OS Known Folder fails explicitly; there is no alternate root. */
    if (base < 3 || base + 24 + 33 > 110 || wcsncmp(local + 1, L":\\", 2)) {
        CoTaskMemFree(local); SetLastError(ERROR_FILENAME_EXCED_RANGE); return 0;
    }
    wmemcpy(profile_root, local, base + 1);
    CoTaskMemFree(local);
    profile_roots[0] = profile_directory(profile_root, 0);
    if (profile_roots[0] == INVALID_HANDLE_VALUE) return 0;
    wmemcpy(profile_root + base, L"\\MetaWork", 10);
    profile_roots[1] = profile_directory(profile_root, 1);
    if (profile_roots[1] == INVALID_HANDLE_VALUE) return 0;
    wmemcpy(profile_root + base + 9, L"\\OfficeProfiles", 16);
    profile_roots[2] = profile_directory(profile_root, 1);
    if (profile_roots[2] == INVALID_HANDLE_VALUE || !profile_recover()) return 0;
    GUID random;
    if (FAILED(CoCreateGuid(&random))) return 0;
    wchar_t identity[33];
    static const wchar_t hex[] = L"0123456789abcdef";
    for (size_t i = 0; i < 16; ++i) {
        unsigned char value = ((unsigned char *)&random)[i];
        identity[2*i] = hex[value >> 4]; identity[2*i+1] = hex[value & 15];
    }
    identity[32] = 0;
    office_job = profile_job(identity, 0);
    if (!office_job || !AssignProcessToJobObject(office_job, GetCurrentProcess())) return 0;
    swprintf(profile_path, 260, L"%ls\\%ls", profile_root, identity);
    swprintf(profile_record, 260, L"%ls.scope", profile_path);
    wchar_t temporary[260];
    swprintf(temporary, 260, L"%ls.next", profile_path);
    HANDLE record = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL, NULL);
    if (record == INVALID_HANDLE_VALUE) return 0;
    unsigned char bytes[40]; DWORD written;
    memcpy(bytes, "MWOFP001", 8);
    for (size_t i = 0; i < 32; ++i) bytes[i+8] = (unsigned char)identity[i];
    int published = WriteFile(record, bytes, sizeof(bytes), &written, NULL) &&
        written == sizeof(bytes) && FlushFileBuffers(record);
    CloseHandle(record);
    if (!published || !MoveFileExW(temporary, profile_record, MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporary); return 0;
    }
    profile_registered = 1;
    if (!CreateDirectoryW(profile_path, NULL)) {
        /* A pre-existing directory was never owned by this invocation. */
        profile_registered = 0;
        DeleteFileW(profile_record);
        return 0;
    }
    profile_owned_directory = CreateFileW(profile_path, DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (profile_owned_directory == INVALID_HANDLE_VALUE) { profile_owned_directory = NULL; return 0; }
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(profile_owned_directory, &info) ||
        !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return 0;
    return SetEnvironmentVariableW(L"METAWORK_OFFICE_PROFILE", profile_path);
}

static int profile_finish(void) {
    if (!profile_registered) return 1;
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = {0};
    if (!QueryInformationJobObject(office_job, JobObjectBasicAccountingInformation,
        &accounting, sizeof(accounting), NULL) || accounting.ActiveProcesses != 1) return 0;
    HANDLE owned = profile_owned_directory;
    profile_owned_directory = NULL;
    if (!profile_remove(profile_path, profile_record, owned)) return 0;
    profile_registered = 0;
    return 1;
}
