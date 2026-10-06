//
//  LibraryTests.swift
//  GameLibraryTests
//
//  Parsing, scanning, classification, normalizing and path resolution.
//

import Foundation
import Testing
@testable import GameLibrary

let compiledAll = [
    CompiledGame(gamedir: "valve", dll: "hl", title: "Half-Life"),
    CompiledGame(gamedir: "gearbox", dll: "opfor", title: "Opposing Force"),
    CompiledGame(gamedir: "bshift", dll: "bshift", title: "Blue Shift"),
]

@Suite struct GameInfoTests {
    @Test func parsesValveLiblist() {
        let info = GameInfo.parseLiblist(hlLiblist)
        #expect(info.title == "Half-Life")
        #expect(info.gamedll == "dlls/hl.dll")
        #expect(info.startMap == "c0a0")
        #expect(info.type == "singleplayer_only")
        #expect(info.gamedllBasenames == ["hl"])
    }

    @Test func blueShiftNamesBshiftBeforeWindowsHL() {
        let info = GameInfo.parseLiblist(bshiftLiblist)
        #expect(info.gamedllBasenames == ["bshift", "hl"])
    }

    @Test func toleratesBareValuesCommentsAndCRLF() {
        let info = GameInfo.parseLiblist("game \"My // Mod\" // trailing\r\nfallback_dir valve\r\n// gamedll \"x.dll\"\r\n")
        #expect(info.title == "My // Mod")
        #expect(info.fallbackDir == "valve")
        #expect(info.gamedll == nil)
    }

    @Test func parsesGameinfoTxt() {
        let info = GameInfo.parseGameInfo("title \"Some Mod\"\ngamedll \"dlls/hl.dll\"\nstartmap \"m1\"\n")
        #expect(info.title == "Some Mod")
        #expect(info.startMap == "m1")
    }
}

@Suite struct ScanTests {
    @Test func attachesOverlaysAndOrdersHalfLifeFirst() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write(["gearbox/liblist.gam": opforLiblist, "gearbox_hd/models/a.mdl": "x",
                       "orphan_hd/models/b.mdl": "y", "steamapps/junk.txt": "z"], under: "GameData")
        let scan = GameScanner(root: box.gameData, compiledGames: compiledAll).scan()
        #expect(scan.games.map(\.gamedir) == ["valve", "gearbox"])
        #expect(scan.game("valve")?.overlays == ["valve_hd"])
        #expect(scan.game("gearbox")?.hdOverlay == "gearbox_hd")
        #expect(scan.orphanOverlays == ["orphan_hd"])
    }

    @Test func classifiesTheKinds() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write([
            "gearbox/liblist.gam": opforLiblist, "gearbox/dlls/opfor.dll": "OF",
            "bshift/liblist.gam": bshiftLiblist,
            // A: no game library at all.
            "maps1/liblist.gam": "game \"Map Pack\"\n",
            // A: gamedll reaching into valve.
            "maps2/liblist.gam": "game \"Map Pack 2\"\ngamedll \"../valve/dlls/hl.dll\"\n",
            // A: ships an untouched copy of Half-Life's library.
            "copy/liblist.gam": "game \"Copy\"\ngamedll \"dlls/hl.dll\"\n", "copy/dlls/hl.dll": "HL-WINDOWS-CODE",
            // C: a modified hl.dll.
            "mine/liblist.gam": "game \"Mine\"\ngamedll \"dlls/hl.dll\"\n", "mine/dlls/hl.dll": "HL-PATCHED!!!!",
            // C: its own library name.
            "other/liblist.gam": "game \"Other\"\ngamedll \"dlls/other.dll\"\n", "other/dlls/other.dll": "x",
            // B by library: a mod running on OF's code.
            "ofmod/liblist.gam": "game \"OF Mod\"\ngamedll \"dlls/opfor.dll\"\nfallback_dir \"gearbox\"\n",
            // A: no gamedll, but dlls/ holds an identical copy.
            "nodll/liblist.gam": "game \"No DLL key\"\n", "nodll/dlls/client.dll": "HL-MAC-CODE",
        ], under: "GameData")
        let scan = GameScanner(root: box.gameData, compiledGames: compiledAll).scan()
        let kinds = Dictionary(uniqueKeysWithValues: scan.games.map { ($0.gamedir, $0.kind) })
        #expect(kinds["valve"] == .base)
        #expect(kinds["gearbox"] == .compiledIn)
        #expect(kinds["bshift"] == .compiledIn)
        #expect(kinds["maps1"] == .contentOnly)
        #expect(kinds["maps2"] == .contentOnly)
        #expect(kinds["copy"] == .contentOnly)
        #expect(kinds["mine"] == .custom)
        #expect(kinds["other"] == .custom)
        #expect(kinds["ofmod"] == .compiledIn)
        #expect(scan.game("ofmod")?.compiledGame?.gamedir == "gearbox")
        #expect(kinds["nodll"] == .contentOnly)
    }

    @Test func blueShiftIsNeverContentOnly() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write(["bshift/liblist.gam": bshiftLiblist, "gearbox/liblist.gam": opforLiblist], under: "GameData")
        // Only Half-Life compiled in (the engine published no table).
        let scan = GameScanner(root: box.gameData, compiledGames: []).scan()
        #expect(scan.game("bshift")?.kind == .custom)
        #expect(scan.game("gearbox")?.kind == .custom)
    }

    @Test func warnsAboutMissingFallbackAndAnniversaryValve() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write(["valve/steam.inf": "PatchVersion=1.1.2.5\n",
                       "mod/liblist.gam": "game \"M\"\nfallback_dir \"gearbox\"\n"], under: "GameData")
        let scan = GameScanner(root: box.gameData, compiledGames: compiledAll).scan()
        #expect(scan.game("valve")?.warnings == [.postAnniversaryValve])
        #expect(scan.game("mod")?.warnings == [.missingFallbackDir("gearbox")])
    }

    @Test func contentChainFollowsHDModFallbackValve() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write(["gearbox/liblist.gam": opforLiblist, "gearbox_hd/models/a.mdl": "x",
                       "ofmod/liblist.gam": "game \"x\"\nfallback_dir \"gearbox\"\n"], under: "GameData")
        let scan = GameScanner(root: box.gameData, compiledGames: compiledAll).scan()
        #expect(scan.game("gearbox")?.contentChain(root: box.gameData.path) == ["gearbox_hd", "gearbox", "valve_hd", "valve"])
        #expect(scan.game("ofmod")?.contentChain(root: box.gameData.path) == ["ofmod", "gearbox", "valve_hd", "valve"])
        #expect(scan.game("valve")?.contentChain(root: box.gameData.path) == ["valve_hd", "valve"])
        let inUse = scan.game("ofmod")!.dirsInUse(root: box.gameData.path, library: scan.games)
        #expect(inUse == ["ofmod", "gearbox", "gearbox_hd", "valve", "valve_hd"])
    }
}

@Suite struct NormalizeTests {
    @Test func writesVFSConfigOnlyWhereAnHDOverlayExists() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write(["gearbox/liblist.gam": opforLiblist], under: "GameData")
        let lib = GameLibrary(root: box.gameData, manifestURL: box.url.appendingPathComponent("m.json"),
                              compiledGames: compiledAll)
        let r = lib.refresh()
        #expect(box.read("GameData/valve/vfs.cfg") == "fs_mount_hd \"1\"\n")
        #expect(!box.exists("GameData/gearbox/vfs.cfg"))
        #expect(r.notes == [.wroteVFSConfig(gamedir: "valve")])
        #expect(Set(r.changed) == ["valve", "gearbox"])
    }

    @Test func keepsAnExistingVFSConfig() throws {
        let box = try Sandbox()
        try writeValve(box)
        try box.write(["valve/VFS.cfg": "fs_mount_hd \"0\"\n"], under: "GameData")
        let lib = GameLibrary(root: box.gameData, manifestURL: nil, compiledGames: compiledAll)
        #expect(lib.refresh().notes == [.keptVFSConfig(gamedir: "valve")])
        #expect(box.names("GameData/valve").contains("VFS.cfg"))
        #expect(box.read("GameData/valve/VFS.cfg") == "fs_mount_hd \"0\"\n")
    }

    @Test func secondLaunchSeesNothingChangedUntilSomethingDoes() throws {
        let box = try Sandbox()
        try writeValve(box)
        let manifest = box.url.appendingPathComponent("m.json")
        _ = GameLibrary(root: box.gameData, manifestURL: manifest, compiledGames: compiledAll).refresh()
        let again = GameLibrary(root: box.gameData, manifestURL: manifest, compiledGames: compiledAll).refresh()
        #expect(again.changed.isEmpty)
        try box.write(["gearbox/liblist.gam": opforLiblist], under: "GameData")
        let third = GameLibrary(root: box.gameData, manifestURL: manifest, compiledGames: compiledAll).refresh()
        #expect(third.changed == ["gearbox"])
        // A different compiled-games table reclassifies everything.
        let fourth = GameLibrary(root: box.gameData, manifestURL: manifest, compiledGames: []).refresh()
        #expect(Set(fourth.changed) == ["valve", "gearbox"])
    }

    @Test func anniversaryHeuristic() throws {
        let box = try Sandbox()
        try box.write(["a/steam.inf": "PatchVersion=1.1.2.2\n", "b/steam.inf": "PatchVersion=1.1.2.3\n",
                       "c/maps/hldemo1.bsp": "x"])
        #expect(!Normalizer.isPostAnniversary(valveDir: box.path("a")))
        #expect(Normalizer.isPostAnniversary(valveDir: box.path("b")))
        #expect(Normalizer.isPostAnniversary(valveDir: box.path("c")))
    }
}

@Suite struct PathResolverTests {
    /// Case-exact existence, so the lookup logic is exercised even on the
    /// Mac's case-insensitive volume.
    static func caseExact() -> PathResolver {
        PathResolver(exists: { path in
            let url = URL(fileURLWithPath: path)
            let parent = url.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: path) else { return false }
            if path == "/" { return true }
            return ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).contains(url.lastPathComponent)
        })
    }

    @Test func findsFilesWhateverTheirCase() throws {
        let box = try Sandbox()
        try box.write(["valve_hd/Models/Hgrunt03.mdl": "hd", "valve/models/player/gordon/gordon.mdl": "g"])
        let r = Self.caseExact()
        #expect(r.resolve("models/hgrunt03.mdl", in: box.path("valve_hd")) == box.path("valve_hd/Models/Hgrunt03.mdl"))
        #expect(r.resolve("MODELS\\Player\\GORDON\\gordon.MDL", in: box.path("valve"))
                == box.path("valve/models/player/gordon/gordon.mdl"))
        #expect(r.resolve("models/missing.mdl", in: box.path("valve")) == nil)
        #expect(r.resolve("../valve/models", in: box.path("valve_hd")) == nil)
        #expect(r.firstMatch("models/HGRUNT03.mdl", in: [box.path("valve"), box.path("valve_hd")])
                == box.path("valve_hd/Models/Hgrunt03.mdl"))
    }

    @Test func seesFilesAddedAfterAListingWasCached() throws {
        let box = try Sandbox()
        try box.write(["d/A.txt": "a"])
        let r = Self.caseExact()
        #expect(r.resolve("a.txt", in: box.path("d")) != nil)
        try box.write(["d/B.txt": "b"])
        #expect(r.resolve("b.txt", in: box.path("d")) == box.path("d/B.txt"))
    }
}

/// Read-only scan of a real asset tree (never normalized: that would write
/// into it). `GAMELIBRARY_REAL_ASSETS=/path/to/HalfLifeAssets swift test`.
@Suite struct RealAssetsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GAMELIBRARY_REAL_ASSETS"] != nil))
    func classifiesTheRealGames() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GAMELIBRARY_REAL_ASSETS"]!)
        let halfLifeOnly = GameScanner(root: root, compiledGames: []).scan()
        let ported = GameScanner(root: root, compiledGames: compiledAll).scan()
        for g in ported.games {
            print("  \(g.gamedir): \(g.kind) (\(g.kindReason)), only HL compiled: \(halfLifeOnly.game(g.gamedir)!.kind), overlays \(g.overlays), chain \(g.contentChain(root: root.path)), warnings \(g.warnings)")
        }
        #expect(ported.game("valve")?.kind == .base)
        if ported.game("bshift") != nil {
            #expect(ported.game("bshift")?.kind == .compiledIn)
            #expect(halfLifeOnly.game("bshift")?.kind == .custom)
        }
        if ported.game("gearbox") != nil {
            #expect(ported.game("gearbox")?.kind == .compiledIn)
            #expect(halfLifeOnly.game("gearbox")?.kind == .custom)
        }
    }
}
