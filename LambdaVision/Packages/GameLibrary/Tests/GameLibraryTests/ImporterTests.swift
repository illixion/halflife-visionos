//
//  ImporterTests.swift
//  GameLibraryTests
//
//  The importer against hostile zips, wrapper folders, whole asset trees,
//  merge vs replace, and the running-game guard.
//

import Foundation
import Testing
@testable import GameLibrary

@Suite struct ImporterTests {
    func importer(_ box: Sandbox, compiled: [CompiledGame] = compiledAll) -> GameImporter {
        GameImporter(library: GameLibrary(root: box.gameData, manifestURL: nil, compiledGames: compiled),
                     stagingRoot: box.staging)
    }

    // MARK: Hostile archives

    @Test(arguments: [
        ("../evil.txt", "dotdot"),
        ("valve/../../evil.txt", "nested dotdot"),
        ("/etc/evil.txt", "absolute"),
        ("..\\evil.txt", "backslash dotdot"),
        ("C:\\evil.txt", "drive letter"),
    ])
    func rejectsEscapingPaths(path: String, label: String) async throws {
        let box = try Sandbox()
        let zip = try box.zip("bad.zip", [.file("mod/liblist.gam", "game \"x\""), .file(path, "pwned")])
        await #expect(throws: ImportError.unsafePath(path)) {
            try await importer(box).run(.zip(zip, deleteWhenDone: false)) { _ in }
        }
        // Nothing was installed, nothing escaped.
        #expect(!box.exists("GameData/mod"))
        #expect(!box.exists("evil.txt"))
        #expect(!FileManager.default.fileExists(atPath: box.url.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    @Test func rejectsSymlinks() async throws {
        let box = try Sandbox()
        let zip = try box.zip("link.zip", [.file("mod/liblist.gam", "game \"x\""),
                                           .symlink("mod/maps", target: "/etc")])
        await #expect(throws: ImportError.symlink("mod/maps")) {
            try await importer(box).run(.zip(zip, deleteWhenDone: true)) { _ in }
        }
        #expect(!box.exists("GameData/mod"))
        #expect(!box.exists("link.zip"))           // an owned copy is deleted even on failure
        #expect(box.names("staging").isEmpty)     // and no work dir is left behind
    }

    @Test func rejectsSymlinksInAnUploadedTree() async throws {
        let box = try Sandbox()
        try box.write(["upload/mod/liblist.gam": "game \"x\""])
        try FileManager.default.createSymbolicLink(atPath: box.path("upload/mod/maps"), withDestinationPath: "/etc")
        await #expect(throws: ImportError.symlink("mod/maps")) {
            try await importer(box).run(.directory(box.url.appendingPathComponent("upload"), consume: false)) { _ in }
        }
    }

    @Test func rejectsArchivesWithoutGamedirs() async throws {
        let box = try Sandbox()
        let zip = try box.zip("photos.zip", [.file("holiday/beach.jpg", "jpg")])
        await #expect(throws: ImportError.noGamedirs) {
            try await importer(box).run(.zip(zip, deleteWhenDone: false)) { _ in }
        }
    }

    // MARK: Finding gamedirs

    @Test func installsAModInsideAModDBWrapperFolder() async throws {
        let box = try Sandbox()
        try writeValve(box)
        let zip = try box.zip("Cool_Mod_v1.2.zip", [
            .dir("Cool Mod v1.2/"), .file("Cool Mod v1.2/README.txt", "read me"),
            .file("Cool Mod v1.2/coolmod/liblist.gam", "game \"Cool Mod\"\n"),
            .file("Cool Mod v1.2/coolmod/maps/cool1.bsp", "bsp"),
            .file("__MACOSX/Cool Mod v1.2/._README.txt", "junk"),
        ])
        let (summary, events) = try await collect(importer(box), .zip(zip, deleteWhenDone: true))
        #expect(summary.installed == ["coolmod"])
        #expect(summary.kinds["coolmod"] == .contentOnly)
        #expect(box.read("GameData/coolmod/maps/cool1.bsp") == "bsp")
        #expect(!box.exists("Cool_Mod_v1.2.zip"))
        #expect(events.contains(.foundGamedir(name: "coolmod", sourcePath: "Cool Mod v1.2/coolmod")))
        #expect(events.contains(.warning(.ignoredEntries(count: 1))))
        #expect(events.last == .finished(summary))
        #expect(events.contains(.progress(completed: 26, total: 26)))   // bytes of the three files kept
    }

    @Test func namesATopLevelGamedirAfterTheArchive() async throws {
        let box = try Sandbox()
        let zip = try box.zip("rocketmod.zip", [.file("liblist.gam", "game \"Rocket\"\n"), .file("maps/r.bsp", "b")])
        let (summary, _) = try await collect(importer(box), .zip(zip, deleteWhenDone: false))
        #expect(summary.installed == ["rocketmod"])
        #expect(box.exists("GameData/rocketmod/maps/r.bsp"))
        #expect(box.exists("rocketmod.zip"))
    }

    @Test func installsAWholeZippedAssetTree() async throws {
        let box = try Sandbox()
        let zip = try box.zip("HalfLifeAssets.zip", [
            .file("HalfLifeAssets/hl_osx", "binary"),
            .file("HalfLifeAssets/steamapps/appmanifest_70.acf", "x"),
            .file("HalfLifeAssets/valve/liblist.gam", hlLiblist),
            .file("HalfLifeAssets/valve/models/v_crowbar.mdl", "m"),
            .file("HalfLifeAssets/valve_hd/models/Hgrunt03.mdl", "hd"),
            .file("HalfLifeAssets/gearbox/liblist.gam", opforLiblist),
            .file("HalfLifeAssets/gearbox_hd/sound/a.wav", "w"),
            .file("HalfLifeAssets/bshift/liblist.gam", bshiftLiblist),
        ])
        let (summary, events) = try await collect(importer(box), .zip(zip, deleteWhenDone: true))
        #expect(Set(summary.installed) == ["valve", "valve_hd", "gearbox", "gearbox_hd", "bshift"])
        #expect(summary.kinds == ["valve": .base, "gearbox": .compiledIn, "bshift": .compiledIn])
        #expect(!box.exists("GameData/steamapps"))
        #expect(!box.exists("GameData/hl_osx"))
        // Case preserved: the resolver, not a rename, handles Hgrunt03.
        #expect(box.names("GameData/valve_hd/models") == ["Hgrunt03.mdl"])
        #expect(box.read("GameData/valve/vfs.cfg") == "fs_mount_hd \"1\"\n")
        #expect(box.read("GameData/gearbox/vfs.cfg") == "fs_mount_hd \"1\"\n")
        #expect(!box.exists("GameData/bshift/vfs.cfg"))
        #expect(events.contains(.normalized(.wroteVFSConfig(gamedir: "valve"))))
    }

    @Test func warnsAboutCustomCodeAndOrphanOverlays() async throws {
        let box = try Sandbox()
        let zip = try box.zip("two.zip", [
            .file("mymod/liblist.gam", "game \"Mine\"\ngamedll \"dlls/mine.dll\"\nfallback_dir \"gearbox\"\n"),
            .file("mymod/dlls/mine.dll", "code"),
            .file("valve_hd/models/a.mdl", "x"),
        ])
        let (summary, events) = try await collect(importer(box), .zip(zip, deleteWhenDone: false))
        #expect(summary.kinds["mymod"] == .custom)
        #expect(events.contains(.warning(.customGameCode(gamedir: "mymod"))))
        #expect(events.contains(.warning(.missingFallbackDir(gamedir: "mymod", fallback: "gearbox"))))
        #expect(events.contains(.warning(.orphanOverlay(gamedir: "valve_hd"))))
    }

    @Test func mergesIntoAnInstalledGamedirWithoutAnInfoFile() async throws {
        let box = try Sandbox()
        try writeValve(box)
        // A map pack that only drops files into valve/.
        let zip = try box.zip("maps.zip", [.file("pack/valve/maps/extra.bsp", "e")])
        let (summary, _) = try await collect(importer(box), .zip(zip, deleteWhenDone: false))
        #expect(summary.installed == ["valve"])
        #expect(box.exists("GameData/valve/maps/extra.bsp"))
        #expect(box.exists("GameData/valve/models/v_9mmhandgun.mdl"))   // merge kept the rest
    }

    // MARK: Merge vs replace

    @Test func mergeFollowsExistingCaseAndReplacesFiles() async throws {
        let box = try Sandbox()
        try box.write(["mod/liblist.gam": "game \"Old\"\n", "mod/Models/keep.mdl": "keep",
                       "mod/Models/Swap.mdl": "old"], under: "GameData")
        let zip = try box.zip("mod.zip", [.file("MOD/liblist.gam", "game \"New\"\n"),
                                          .file("MOD/models/swap.mdl", "new"), .file("MOD/models/add.mdl", "add")])
        let (summary, _) = try await collect(importer(box), .zip(zip, deleteWhenDone: false))
        #expect(summary.installed == ["mod"])                       // the on-disk name wins
        #expect(box.names("GameData") == ["mod"])
        #expect(box.names("GameData/mod/Models") == ["add.mdl", "keep.mdl", "swap.mdl"])
        #expect(box.read("GameData/mod/Models/swap.mdl") == "new")
        #expect(box.read("GameData/mod/liblist.gam") == "game \"New\"\n")
    }

    @Test func replaceSwapsTheWholeGamedir() async throws {
        let box = try Sandbox()
        try box.write(["mod/liblist.gam": "game \"Old\"\n", "mod/maps/stale.bsp": "old"], under: "GameData")
        let zip = try box.zip("mod.zip", [.file("mod/liblist.gam", "game \"New\"\n"), .file("mod/maps/new.bsp", "n")])
        let (summary, events) = try await collect(importer(box), .zip(zip, deleteWhenDone: false),
                                                  ImportOptions(modes: ["mod": .replace]))
        #expect(events.contains(.installed(gamedir: "mod", mode: .replace, files: 2)))
        #expect(summary.installed == ["mod"])
        #expect(!box.exists("GameData/mod/maps/stale.bsp"))
        #expect(box.exists("GameData/mod/maps/new.bsp"))
        #expect(box.names("staging").isEmpty)
    }

    @Test func copiesAPickedFolderAndLeavesItIntact() async throws {
        let box = try Sandbox()
        try box.write(["Picked/coolmod/liblist.gam": "game \"Cool\"\n", "Picked/coolmod/maps/a.bsp": "aaaa"])
        let (summary, events) = try await collect(
            importer(box), .directory(box.url.appendingPathComponent("Picked"), consume: false))
        #expect(summary.installed == ["coolmod"])
        #expect(box.exists("GameData/coolmod/maps/a.bsp"))
        #expect(box.exists("Picked/coolmod/maps/a.bsp"))
        #expect(events.contains { if case .progress(let c, let t) = $0 { return c == t && t > 0 } else { return false } })
    }

    @Test func consumesAnUploadTree() async throws {
        let box = try Sandbox()
        try box.write(["Upload/coolmod/liblist.gam": "game \"Cool\"\n", "Upload/coolmod/maps/a.bsp": "a"])
        _ = try await collect(importer(box), .directory(box.url.appendingPathComponent("Upload"), consume: true))
        #expect(box.exists("GameData/coolmod/maps/a.bsp"))
        #expect(!box.exists("Upload/coolmod"))
    }

    // MARK: The running game

    @Test func refusesGamedirsTheRunningGameReads() async throws {
        let box = try Sandbox()
        try writeValve(box)
        let zip = try box.zip("mix.zip", [.file("valve_hd/models/new.mdl", "x"),
                                          .file("coolmod/liblist.gam", "game \"Cool\"\n")])
        let (summary, events) = try await collect(importer(box), .zip(zip, deleteWhenDone: false),
                                                  ImportOptions(protectedGamedirs: ["VALVE"]))
        #expect(summary.refused == ["valve_hd"])
        #expect(summary.installed == ["coolmod"])
        #expect(events.contains(.refusedInUse(gamedir: "valve_hd")))
        #expect(!box.exists("GameData/valve_hd/models/new.mdl"))
    }

    @Test func failsWhenEverythingIsInUse() async throws {
        let box = try Sandbox()
        try writeValve(box)
        let zip = try box.zip("v.zip", [.file("valve/maps/x.bsp", "x")])
        await #expect(throws: ImportError.gameInUse(["valve"])) {
            try await importer(box).run(.zip(zip, deleteWhenDone: false),
                                        options: ImportOptions(protectedGamedirs: ["valve"])) { _ in }
        }
    }

    @Test func streamsEventsAsAnAsyncSequence() async throws {
        let box = try Sandbox()
        let zip = try box.zip("m.zip", [.file("m/liblist.gam", "game \"M\"\n")])
        var phases: [ImportPhase] = []
        var finished = false
        for try await e in importer(box).events(.zip(zip, deleteWhenDone: false)) {
            if case .phase(let p) = e { phases.append(p) }
            if case .finished = e { finished = true }
        }
        #expect(finished)
        #expect(phases == [.validating, .extracting, .locating, .installing, .normalizing, .cleaningUp])
    }
}
