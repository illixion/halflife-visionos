// Checks the launcher's chapter lists and save-file map sniffing.
// Launcher/ChapterCatalog.swift is compiled verbatim (build.sh).

import Foundation

func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
func check(_ ok: Bool, _ m: @autoclosure () -> String) { if !ok { die(m()) } }

let assets = CommandLine.arguments.dropFirst().first ?? ""

for (gamedir, chapters) in ChapterCatalog.games {
    check(Set(chapters.map(\.map)).count == chapters.count, "\(gamedir): chapter maps are unique")
    check(chapters.map(\.number) == Array(1...chapters.count), "\(gamedir): numbered 1...n")
    check(chapters.allSatisfy { !$0.title.isEmpty }, "\(gamedir): titles")
    if FileManager.default.fileExists(atPath: "\(assets)/\(gamedir)/maps") {
        for c in chapters {
            check(FileManager.default.fileExists(atPath: "\(assets)/\(gamedir)/maps/\(c.map).bsp"),
                  "\(gamedir): map \(c.map) (\(c.title)) is installed")
        }
        print("\(gamedir): \(chapters.count) chapter maps found")
    }
}

// Which chapter a map belongs to.
func chap(_ map: String, _ game: String = "valve") -> String? { ChapterCatalog.chapter(containing: map, in: game)?.map }
check(chap("c1a2d") == "c1a2", "c1a2d is in c1a2: \(String(describing: chap("c1a2d")))")
check(chap("c1a0e") == "c1a0", "c1a0e is in c1a0")
check(chap("c2a2b1") == "c2a2", "c2a2b1 is in c2a2")
check(chap("c0a0c") == "c0a0", "c0a0c is in c0a0")
check(chap("t0a0b") == "t0a0", "t0a0b is in the hazard course")
check(chap("c4a1f") == "c4a1", "c4a1f is in Xen")
check(chap("of3a2", "gearbox") == "of3a1", "of3a2 follows of3a1: \(String(describing: chap("of3a2", "gearbox")))")
check(chap("of1a4b", "gearbox") == "of1a3", "of1a4b follows of1a3")
check(chap("ba_tram3", "bshift") == "ba_tram1", "ba_tram3 is in the tram chapter")
check(chap("ba_yard4a", "bshift") == "ba_yard1", "ba_yard4a is in captive freight")
check(chap("zzz", "valve") == nil, "an unknown map has no chapter")
check(ChapterCatalog.chapters(for: "somemod").isEmpty, "an unknown game has no chapters")

// Save header sniffing.
func save(_ map: String) -> Data {
    var d = Data("JSAV".utf8)
    d.append(contentsOf: [0x71, 0, 0, 0, 0x10, 0, 0, 0])
    d.append(Data("GAME HEADER".utf8)); d.append(0)
    d.append(contentsOf: [3, 0, 0, 0]); d.append(Data(map.utf8)); d.append(0)
    d.append(Data(repeating: 0, count: 64)); d.append(Data("c9a9zzz".utf8))
    return d
}
check(ChapterCatalog.mapName(inSave: save("c1a2d")) == "c1a2d", "sniffs a c-map")
check(ChapterCatalog.mapName(inSave: save("of3a1b")) == "of3a1b", "sniffs an of-map")
check(ChapterCatalog.mapName(inSave: save("ba_tram2")) == "ba_tram2", "sniffs a ba-map")
check(ChapterCatalog.mapName(inSave: Data("nothing here".utf8)) == nil, "no map in noise")

print("launcher checks passed")
