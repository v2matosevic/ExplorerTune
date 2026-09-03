<#
    Windows Search crawl scope, through the supported COM API.
    Dot-source this; it defines the ET.Search.Api class and nothing else.

    WHY THIS FILE IS SHAPED LIKE THIS
    ---------------------------------
    The crawl scope cannot be set from the registry. The keys under
    HKLM\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager deny writes even to
    an elevated Administrator, and the WSearch service rewrites them on every
    start. `ISearchCrawlScopeManager` is the only durable route, and it is what
    the Indexing Options dialog itself calls.

    These interfaces ship no type library, so there is nothing to import. Worse,
    the IIDs published for them are not always the ones a given Windows build
    actually implements: on 10.0.26100 the object returned by GetCatalog answers
    to AB310581-AC80-11D1-8DF3-00C04FB6EF50, and refuses the widely quoted
    ...EF61 and ...EF62.

    So instead of hardcoding, this discovers the interfaces at runtime:

      1. QueryInterface sweep to find which IIDs the object really implements.
         QI is read-only and cannot have side effects, so sweeping is safe.
      2. Anchor the vtable with READ-ONLY methods whose correct answer is
         already known: get_Name must return the catalog name we asked for, and
         IncludedInCrawlScope must be right about a path that must be in scope
         AND one that must not. A layout off by one slot cannot satisfy both.
      3. Only if both anchors land where the documented layout says do we trust
         the positions of the MUTATING methods. If an anchor is missing or in an
         unexpected place, Validated stays false and every mutating call throws.

    That last point is the whole safety model. ISearchCatalogManager has Reset()
    at slot 5 and the scope manager has RevertToDefaultScopes() at slot 13, so
    calling a misidentified slot is not a crash, it is data loss.

    Calls go through raw vtable pointers rather than [ComImport] interfaces for
    two reasons: a [ComImport] Guid is a compile-time constant and cannot carry
    a discovered IID, and PowerShell cannot call these interfaces at all (it
    dispatches COM through IDispatch, which they do not implement, so a cast
    arrives as a bare System.__ComObject with no methods on it).
#>

if (-not ('ET.Search.Api' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ET.Search {

public static class Api {

    // ---- COM plumbing -----------------------------------------------------

    // The first three vtable entries are always IUnknown's.
    const int IUNKNOWN_SLOTS = 3;

    static readonly Guid CLSID_CSearchManager = new Guid("7D096C5F-AC08-4F1F-BEB7-5C22C517CE39");
    // Stable and documented; the only IID here that is not discovered.
    static readonly Guid IID_ISearchManager   = new Guid("AB310581-AC80-11D1-8DF3-00C04FB6EF69");

    // Documented 1-based method positions, from searchapi.h.
    const int SLOT_GET_CATALOG            = 8;   // ISearchManager
    const int SLOT_CAT_GET_NAME           = 1;   // ISearchCatalogManager
    const int SLOT_CAT_STATUS             = 4;
    const int SLOT_CAT_NUMBER_OF_ITEMS    = 13;
    const int SLOT_CAT_GET_SCOPE_MANAGER  = 26;
    const int SLOT_CSM_ADD_USER_RULE      = 6;   // ISearchCrawlScopeManager
    const int SLOT_CSM_INCLUDED_IN_SCOPE  = 11;
    const int SLOT_CSM_SAVE_ALL           = 14;

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int OutPtr(IntPtr self, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int StrOutPtr(IntPtr self, [MarshalAs(UnmanagedType.LPWStr)] string s, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int TwoOutInt(IntPtr self, out int a, out int b);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int OutInt(IntPtr self, out int a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int StrOutInt(IntPtr self, [MarshalAs(UnmanagedType.LPWStr)] string s, out int a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int AddRuleFn(IntPtr self, [MarshalAs(UnmanagedType.LPWStr)] string url, int include, int overrideChildren, uint followFlags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int NoArgs(IntPtr self);

    static T Method<T>(IntPtr pUnk, int documentedSlot) where T : class {
        IntPtr vtbl = Marshal.ReadIntPtr(pUnk);
        IntPtr fn = Marshal.ReadIntPtr(vtbl, (IUNKNOWN_SLOTS + documentedSlot - 1) * IntPtr.Size);
        return Marshal.GetDelegateForFunctionPointer(fn, typeof(T)) as T;
    }

    static string TakeString(IntPtr p) {
        if (p == IntPtr.Zero) return null;
        string s = Marshal.PtrToStringUni(p);
        Marshal.FreeCoTaskMem(p);
        return s;
    }

    // ---- discovery state --------------------------------------------------

    static IntPtr _cat = IntPtr.Zero;
    static IntPtr _csm = IntPtr.Zero;

    public static Guid CatalogIid;
    public static Guid ScopeIid;
    public static bool Validated;
    public static string Report = "";

    static readonly List<string> _log = new List<string>();
    static void L(string s) { _log.Add(s); }

    /// Every IID of the AB310581-AC80-11D1-8DF3-00C04FB6EFxx family that this
    /// object answers to. QueryInterface is read-only, so this cannot break
    /// anything, and it is how the real IIDs were found in the first place.
    static List<Guid> SupportedIids(IntPtr pUnk) {
        var found = new List<Guid>();
        for (int lo = 0x00; lo <= 0xFF; lo++) {
            Guid iid = new Guid(string.Format("AB310581-AC80-11D1-8DF3-00C04FB6EF{0:X2}", lo));
            IntPtr p;
            if (Marshal.QueryInterface(pUnk, in iid, out p) == 0) {
                found.Add(iid);
                Marshal.Release(p);
            }
        }
        return found;
    }

    static IntPtr QI(IntPtr pUnk, Guid iid) {
        IntPtr p;
        return Marshal.QueryInterface(pUnk, in iid, out p) == 0 ? p : IntPtr.Zero;
    }

    /// <summary>
    /// Connects and proves the interface layout. Returns a human-readable
    /// report. Validated is only true if every anchor checked out; while it is
    /// false, the mutating calls refuse to run.
    /// </summary>
    /// <param name="catalog">catalog name, normally "SystemIndex"</param>
    /// <param name="mustBeInScope">a URL that MUST currently be in scope</param>
    /// <param name="mustBeOutOfScope">a URL that MUST NOT be in scope</param>
    public static string Discover(string catalog, string mustBeInScope, string mustBeOutOfScope) {
        _log.Clear();
        Validated = false;

        object inst = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_CSearchManager, true));
        IntPtr pInst = Marshal.GetIUnknownForObject(inst);
        IntPtr pMgr = QI(pInst, IID_ISearchManager);
        Marshal.Release(pInst);
        if (pMgr == IntPtr.Zero) {
            L("FAIL: the search manager does not implement ISearchManager (...EF69).");
            Report = string.Join(Environment.NewLine, _log);
            return Report;
        }
        L("ISearchManager        " + IID_ISearchManager.ToString().ToUpper());

        // --- catalog ---
        IntPtr pCatUnk;
        int hr = Method<StrOutPtr>(pMgr, SLOT_GET_CATALOG)(pMgr, catalog, out pCatUnk);
        Marshal.Release(pMgr);
        if (hr != 0 || pCatUnk == IntPtr.Zero) {
            L("FAIL: GetCatalog(\"" + catalog + "\") returned 0x" + hr.ToString("X8"));
            Report = string.Join(Environment.NewLine, _log);
            return Report;
        }

        // Which of the candidate IIDs gives us an object whose get_Name returns
        // the catalog name we asked for? That single check validates the IID and
        // the get_Name slot together.
        var catCandidates = SupportedIids(pCatUnk);
        L("catalog object implements " + catCandidates.Count + " candidate IID(s)");
        foreach (Guid iid in catCandidates) {
            IntPtr p = QI(pCatUnk, iid);
            if (p == IntPtr.Zero) continue;
            string name = null;
            try {
                IntPtr sp;
                if (Method<OutPtr>(p, SLOT_CAT_GET_NAME)(p, out sp) == 0) name = TakeString(sp);
            }
            catch { }
            if (name == catalog) {
                _cat = p;
                CatalogIid = iid;
                L("ISearchCatalogManager " + iid.ToString().ToUpper() + "   get_Name -> \"" + name + "\" OK");
                break;
            }
            Marshal.Release(p);
        }
        Marshal.Release(pCatUnk);
        if (_cat == IntPtr.Zero) {
            L("FAIL: no candidate IID produced a catalog whose get_Name returned \"" + catalog + "\".");
            Report = string.Join(Environment.NewLine, _log);
            return Report;
        }

        // --- scope manager ---
        IntPtr pCsmUnk;
        hr = Method<OutPtr>(_cat, SLOT_CAT_GET_SCOPE_MANAGER)(_cat, out pCsmUnk);
        if (hr != 0 || pCsmUnk == IntPtr.Zero) {
            L("FAIL: GetCrawlScopeManager returned 0x" + hr.ToString("X8"));
            Report = string.Join(Environment.NewLine, _log);
            return Report;
        }

        // Two-sided oracle. A wrong IID or a shifted vtable cannot be right
        // about a path that must be in scope AND one that must not be.
        var csmCandidates = SupportedIids(pCsmUnk);
        L("scope object implements " + csmCandidates.Count + " candidate IID(s)");
        foreach (Guid iid in csmCandidates) {
            IntPtr p = QI(pCsmUnk, iid);
            if (p == IntPtr.Zero) continue;
            try {
                int inRes, outRes;
                var f = Method<StrOutInt>(p, SLOT_CSM_INCLUDED_IN_SCOPE);
                if (f(p, mustBeInScope, out inRes) == 0 && f(p, mustBeOutOfScope, out outRes) == 0) {
                    if (inRes != 0 && outRes == 0) {
                        _csm = p;
                        ScopeIid = iid;
                        L("ISearchCrawlScopeManager " + iid.ToString().ToUpper());
                        L("  IncludedInCrawlScope(\"" + mustBeInScope + "\") = true   (required)");
                        L("  IncludedInCrawlScope(\"" + mustBeOutOfScope + "\") = false  (required)");
                        break;
                    }
                }
            }
            catch { }
            Marshal.Release(p);
        }
        Marshal.Release(pCsmUnk);
        if (_csm == IntPtr.Zero) {
            L("FAIL: no candidate IID satisfied the two-sided scope oracle.");
            L("      Refusing to mutate. The vtable layout on this build differs");
            L("      from the documented one; see docs/search-scope.md.");
            Report = string.Join(Environment.NewLine, _log);
            return Report;
        }

        Validated = true;
        L("layout validated - mutating calls are enabled");
        Report = string.Join(Environment.NewLine, _log);
        return Report;
    }

    static void RequireValid() {
        if (!Validated || _csm == IntPtr.Zero)
            throw new InvalidOperationException(
                "Interface layout was not validated; refusing to call a mutating method. " +
                "Run Discover() and read its report.");
    }

    // ---- read-only --------------------------------------------------------

    public static string CatalogName() {
        IntPtr sp;
        return Method<OutPtr>(_cat, SLOT_CAT_GET_NAME)(_cat, out sp) == 0 ? TakeString(sp) : null;
    }

    public static int Status() {
        int s, p;
        return Method<TwoOutInt>(_cat, SLOT_CAT_STATUS)(_cat, out s, out p) == 0 ? s : -1;
    }

    public static int ItemCount() {
        int n;
        return Method<OutInt>(_cat, SLOT_CAT_NUMBER_OF_ITEMS)(_cat, out n) == 0 ? n : -1;
    }

    public static bool IsInScope(string url) {
        int r;
        if (Method<StrOutInt>(_csm, SLOT_CSM_INCLUDED_IN_SCOPE)(_csm, url, out r) != 0)
            throw new COMException("IncludedInCrawlScope failed for " + url);
        return r != 0;
    }

    // ---- mutating (gated on Validated) ------------------------------------

    public static void AddRule(string url, bool include, bool overrideChildren) {
        RequireValid();
        int hr = Method<AddRuleFn>(_csm, SLOT_CSM_ADD_USER_RULE)(
            _csm, url, include ? 1 : 0, overrideChildren ? 1 : 0, 0);
        if (hr != 0) throw new COMException("AddUserScopeRule failed for " + url, hr);
    }

    public static void SaveAll() {
        RequireValid();
        int hr = Method<NoArgs>(_csm, SLOT_CSM_SAVE_ALL)(_csm);
        if (hr != 0) throw new COMException("SaveAll failed", hr);
    }
}
}
'@
}

function Get-SearchCatalogStatusName {
    param([int]$Code)
    switch ($Code) {
        0 { 'Idle' } 1 { 'Paused' } 2 { 'Recovering' } 3 { 'Full crawl' }
        4 { 'Incremental crawl' } 5 { 'Processing notifications' } 6 { 'Shutting down' }
        default { "unknown ($Code)" }
    }
}

function Connect-SearchApi {
    <#
    .SYNOPSIS
      Connects to the search catalog and proves the COM interface layout.
    .DESCRIPTION
      Picks its own oracle paths: the user's Desktop must be in scope (it is
      indexed by default on every Windows install) and %WINDIR% must not be
      (it is excluded by default on every Windows install). Both come from the
      shipped default rules, so they hold on a stock machine.

      Returns $true only if the layout validated.
    #>
    [CmdletBinding()]
    param(
        [string]$Catalog = 'SystemIndex',
        [string]$MustBeInScope,
        [string]$MustBeOutOfScope
    )
    if (-not $MustBeInScope) { $MustBeInScope = 'file:///' + [Environment]::GetFolderPath('Desktop') + '\' }
    if (-not $MustBeOutOfScope) { $MustBeOutOfScope = 'file:///' + $env:WINDIR + '\' }

    $report = [ET.Search.Api]::Discover($Catalog, $MustBeInScope, $MustBeOutOfScope)
    $report -split "`n" | ForEach-Object { Write-Verbose $_ }
    return [pscustomobject]@{
        Validated  = [ET.Search.Api]::Validated
        CatalogIid = [ET.Search.Api]::CatalogIid
        ScopeIid   = [ET.Search.Api]::ScopeIid
        Report     = $report
    }
}
