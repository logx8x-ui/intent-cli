import Foundation

/// Ordinary resource closure is completion only when the entire explicit
/// whitelist is gone. Unknown native or browser inventory never proves closure.
public enum SelectedResourceLifetime {
    public enum BrowserPresence { case present, unknown, closed }

    /// Static snapshot of https://www.google.com/supported_domains (2026-10-12).
    /// Exact membership prevents attacker-owned suffixes from becoming search.
    public static let supportedGoogleSearchHosts: Set<String> = Set("""
    google.com google.ad google.ae google.com.af google.com.ag google.al google.am google.co.ao
    google.com.ar google.as google.at google.com.au google.az google.ba google.com.bd google.be
    google.bf google.bg google.com.bh google.bi google.bj google.com.bn google.com.bo google.com.br
    google.bs google.bt google.co.bw google.by google.com.bz google.ca google.cd google.cf
    google.cg google.ch google.ci google.co.ck google.cl google.cm google.cn google.com.co
    google.co.cr google.com.cu google.cv google.com.cy google.cz google.de google.dj google.dk
    google.dm google.com.do google.dz google.com.ec google.ee google.com.eg google.es google.com.et
    google.fi google.com.fj google.fm google.fr google.ga google.ge google.gg google.com.gh
    google.com.gi google.gl google.gm google.gr google.com.gt google.gy google.com.hk google.hn
    google.hr google.ht google.hu google.co.id google.ie google.co.il google.im google.co.in
    google.iq google.is google.it google.je google.com.jm google.jo google.co.jp google.co.ke
    google.com.kh google.ki google.kg google.co.kr google.com.kw google.kz google.la google.com.lb
    google.li google.lk google.co.ls google.lt google.lu google.lv google.com.ly google.co.ma
    google.md google.me google.mg google.mk google.ml google.com.mm google.mn google.com.mt
    google.mu google.mv google.mw google.com.mx google.com.my google.co.mz google.com.na google.com.ng
    google.com.ni google.ne google.nl google.no google.com.np google.nr google.nu google.co.nz
    google.com.om google.com.pa google.com.pe google.com.pg google.com.ph google.com.pk google.pl google.pn
    google.com.pr google.ps google.pt google.com.py google.com.qa google.ro google.ru google.rw
    google.com.sa google.com.sb google.sc google.se google.com.sg google.sh google.si google.sk
    google.com.sl google.sn google.so google.sm google.sr google.st google.com.sv google.td
    google.tg google.co.th google.com.tj google.tl google.tm google.tn google.to google.com.tr
    google.tt google.com.tw google.co.tz google.com.ua google.co.ug google.co.uk google.com.uy google.co.uz
    google.com.vc google.co.ve google.co.vi google.com.vn google.vu google.ws google.rs google.co.za
    google.co.zm google.co.zw google.cat
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Persisted intentions include app presets for enforcement. Those defaults
    /// are not selected work and cannot keep an exhausted session alive.
    public static func wholeAppSelections(allowedAppIDs: Set<String>, presetAppIDs: Set<String>,
                                          windowSelectionAppIDs: Set<String>, tabSelectionAppIDs: Set<String>) -> Set<String> {
        allowedAppIDs.subtracting(presetAppIDs).subtracting(windowSelectionAppIDs).subtracting(tabSelectionAppIDs)
    }

    /// Ordinary snapshots can remain idle after a close. A missing selected ID
    /// always needs a new exact-owner query; timestamp age cannot suppress it.
    public static func needsTabConfirmation(restrictive: Bool, snapshot: BrowserTabSnapshot,
                                            selectedIDs: Set<Int>, searchSessionID: String? = nil) -> Bool {
        restrictive && !hasRemainingTabs(snapshot: snapshot, selectedIDs: selectedIDs, searchSessionID: searchSessionID)
    }

    /// Only an exact current Browser Guard search ledger can extend selected
    /// work. An old Google tab or a holding page never acquires that authority.
    public static func hasRemainingTabs(snapshot: BrowserTabSnapshot, selectedIDs: Set<Int>,
                                        searchSessionID: String? = nil) -> Bool {
        (snapshot.allTabs ?? snapshot.tabs).contains {
            selectedIDs.contains($0.id) || isRuntimeSearchTab($0, searchSessionID: searchSessionID)
        }
    }
    public static func isRuntimeSearchTab(_ tab: BrowserTabItem, searchSessionID: String?) -> Bool {
        guard let searchSessionID, !searchSessionID.isEmpty, tab.searchSessionID == searchSessionID,
              tab.id >= 0, tab.windowID >= 0 else { return false }
        let value = tab.url.lowercased()
        if value.isEmpty || ["about:blank", "about:newtab"].contains(value)
            || value.range(of: "^chrome://(?:newtab|new-tab-page)(?:/|$)", options: .regularExpression) != nil
            || value.hasPrefix("chrome-search://") { return true }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
              let rawHost = url.host else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard supportedGoogleSearchHosts.contains(host) else { return false }
        let path = url.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return path.isEmpty || path == "/search"
    }

    public static func shouldFinish(restrictive: Bool,
                                    selectedWindows: [String: Set<UInt32>],
                                    wholeApps: Set<String>,
                                    liveWindows: [String: Set<UInt32>]?,
                                    browsers: [String: BrowserPresence]) -> Bool {
        guard restrictive else { return false }
        if browsers.values.contains(where: { $0 != .closed }) { return false }
        let nativeSelections = selectedWindows.filter { browsers[$0.key] == nil }
        // A browser's confirmed tab closure remains authoritative even when
        // WindowServer is unavailable; native targets need a complete query.
        if !wholeApps.isEmpty || !nativeSelections.isEmpty {
            guard let liveWindows else { return false }
            for app in wholeApps where !(liveWindows[app] ?? []).isEmpty { return false }
            for (app, selected) in nativeSelections {
                if !selected.isDisjoint(with: liveWindows[app] ?? []) { return false }
            }
        }
        return !selectedWindows.isEmpty || !wholeApps.isEmpty || !browsers.isEmpty
    }
}
