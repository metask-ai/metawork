# Attributes every thread of a running Host process to the routine it was
# created with, so a thread count can be read as "which spawn site owns these".
# Emits one JSON object on the last stdout line: the thread total and the
# per-start-address histogram with resolved symbol and source lines.
param(
  [Parameter(Mandatory = $true)][int]$ProcessId,
  [Parameter(Mandatory = $true)][string]$SymbolPath
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Dbg {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenThread(uint access, bool inherit, int tid);

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationThread(IntPtr thread, int infoClass, out ulong info, int length, IntPtr returnLength);

    // ThreadQuerySetWin32StartAddress (9): the routine passed to
    // CreateThread, which is what identifies the spawn site. .NET's
    // ProcessThread.StartAddress reports ntdll!RtlUserThreadStart for every
    // thread and cannot attribute anything.
    public static ulong Win32StartAddress(int tid) {
        IntPtr thread = OpenThread(0x0040, false, tid);
        if (thread == IntPtr.Zero) return 0;
        try {
            ulong address = 0;
            if (NtQueryInformationThread(thread, 9, out address, 8, IntPtr.Zero) != 0) return 0;
            return address;
        } finally {
            CloseHandle(thread);
        }
    }

    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern bool SymInitialize(IntPtr process, string searchPath, bool invade);
    [DllImport("dbghelp.dll", SetLastError = true)]
    public static extern bool SymCleanup(IntPtr process);
    [DllImport("dbghelp.dll")]
    public static extern uint SymSetOptions(uint options);

    [StructLayout(LayoutKind.Sequential)]
    public struct SYMBOL_INFO {
        public uint SizeOfStruct;
        public uint TypeIndex;
        public ulong Reserved0;
        public ulong Reserved1;
        public uint Index;
        public uint Size;
        public ulong ModBase;
        public uint Flags;
        public ulong Value;
        public ulong Address;
        public uint Register;
        public uint Scope;
        public uint Tag;
        public int NameLen;
        public int MaxNameLen;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)]
        public string Name;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IMAGEHLP_LINE64 {
        public uint SizeOfStruct;
        public IntPtr Key;
        public uint LineNumber;
        public IntPtr FileName;
        public ulong Address;
    }

    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern bool SymFromAddr(IntPtr process, ulong address, out ulong displacement, ref SYMBOL_INFO symbol);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern bool SymGetLineFromAddr64(IntPtr process, ulong address, out uint displacement, ref IMAGEHLP_LINE64 line);

    public static string Symbol(IntPtr process, ulong address) {
        SYMBOL_INFO info = new SYMBOL_INFO();
        // SizeOfStruct must be sizeof(SYMBOL_INFO) as dbghelp declares it,
        // whose Name is CHAR[1]; it is not Marshal.SizeOf of this managed
        // mirror, which carries the 1024-byte receive buffer inline.
        info.SizeOfStruct = 88;
        info.MaxNameLen = 1024;
        ulong displacement = 0;
        if (!SymFromAddr(process, address, out displacement, ref info)) return null;
        return info.Name + "+0x" + displacement.ToString("x");
    }

    public static string Line(IntPtr process, ulong address) {
        IMAGEHLP_LINE64 line = new IMAGEHLP_LINE64();
        line.SizeOfStruct = (uint)Marshal.SizeOf(typeof(IMAGEHLP_LINE64));
        uint displacement = 0;
        if (!SymGetLineFromAddr64(process, address, out displacement, ref line)) return null;
        string file = line.FileName == IntPtr.Zero ? "?" : Marshal.PtrToStringAnsi(line.FileName);
        return file + ":" + line.LineNumber;
    }
}
'@

# PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
$handle = [Dbg]::OpenProcess(0x0410, $false, $ProcessId)
if ($handle -eq [IntPtr]::Zero) { throw "OpenProcess failed for pid $ProcessId" }

# UNDNAME | DEFERRED_LOADS | LOAD_LINES | NO_PROMPTS | FAIL_CRITICAL_ERRORS
[void][Dbg]::SymSetOptions(0x00000002 -bor 0x00000004 -bor 0x00000010 -bor 0x00080000 -bor 0x00000200)
if (-not [Dbg]::SymInitialize($handle, $SymbolPath, $true)) {
  [void][Dbg]::CloseHandle($handle)
  throw "SymInitialize failed"
}

try {
  $threads = (Get-Process -Id $ProcessId).Threads
  $groups = @{}
  $unattributed = 0
  foreach ($thread in $threads) {
    $address = [Dbg]::Win32StartAddress($thread.Id)
    if ($address -eq 0) {
      # A thread that exited between enumeration and the query, or one this
      # token cannot open, has no attribution. ProcessThread.StartAddress is
      # not a substitute: it reports ntdll!RtlUserThreadStart for every thread,
      # so taking it here would merge unrelated threads into one bogus group.
      $unattributed += 1
      continue
    }
    $key = $address.ToString('x')
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = [pscustomobject]@{
        startAddress = "0x$key"
        count        = 0
        symbol       = [Dbg]::Symbol($handle, $address)
        lines        = @()
      }
      # Line info follows inlining, so sampling a few bytes into the entry
      # names the callee that ReleaseFast inlined into the thread entry.
      foreach ($offset in 0, 8, 16, 32, 64, 128, 256) {
        $line = [Dbg]::Line($handle, $address + $offset)
        if ($line -and ($groups[$key].lines -notcontains $line)) {
          $groups[$key].lines += $line
        }
      }
    }
    $groups[$key].count += 1
  }
  [pscustomobject]@{
    pid           = $ProcessId
    threadCount   = $threads.Count
    attributed    = ($threads.Count - $unattributed)
    unattributed  = $unattributed
    distinct      = $groups.Count
    groups        = @($groups.Values | Sort-Object -Property count -Descending)
  } | ConvertTo-Json -Depth 5 -Compress
} finally {
  [void][Dbg]::SymCleanup($handle)
  [void][Dbg]::CloseHandle($handle)
}
