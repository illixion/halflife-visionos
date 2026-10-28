// Checks the settings preset format and the presets that ship.
// SettingsPreset.swift and BuiltInPresets.swift are compiled verbatim
// (build.sh), so what passes here is what the app reads. Exits non-zero on
// the first failure.

import Foundation

func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
func check(_ ok: Bool, _ m: @autoclosure () -> String) { if !ok { die(m()) } }

let args = Array(CommandLine.arguments.dropFirst())
let bindingsText = (try? String(contentsOfFile: args[0], encoding: .utf8)) ?? ""
let settingsText = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""

// MARK: Schema

let ids = PresetSchema.specs.map(\.id)
check(Set(ids).count == ids.count, "setting ids are unique")
for c in PresetCategory.allCases { check(!PresetSchema.specs(in: c).isEmpty, "\(c) has settings") }
for spec in PresetSchema.specs {
    check(spec.title != spec.id, "\(spec.id) has a title")
    if case .number(let r) = spec.kind { check(r.lowerBound < r.upperBound, "\(spec.id) range") }
    if case .choice(let o) = spec.kind { check(!o.isEmpty && Set(o).count == o.count, "\(spec.id) options") }
}

// Every schema id is bound to a GameSettings property, and nothing else is.
do {
    let pattern = try NSRegularExpression(pattern: "^\\s+\"(\\w+)\": (?:flag|number|choice)\\(\\\\\\.(\\w+)\\),", options: [.anchorsMatchLines])
    let range = NSRange(bindingsText.startIndex..., in: bindingsText)
    var bound: [String: String] = [:]
    for m in pattern.matches(in: bindingsText, range: range) {
        let id = String(bindingsText[Range(m.range(at: 1), in: bindingsText)!])
        let prop = String(bindingsText[Range(m.range(at: 2), in: bindingsText)!])
        check(id == prop, "binding \(id) reads property \(prop): ids are property names")
        check(settingsText.contains("var \(prop):"), "GameSettings has \(prop)")
        bound[id] = prop
    }
    check(Set(bound.keys) == Set(ids), "bindings and schema agree: only in bindings \(Set(bound.keys).subtracting(ids).sorted()), only in schema \(Set(ids).subtracting(bound.keys).sorted())")
}

// Choice options match the enums' cases in GameSettings.swift.
do {
    let enums: [(id: String, type: String)] = [
        ("waterMirrorMethod", "WaterMirrorMethod"), ("weaponModel", "WeaponModelStyle"),
        ("aimReticle", "AimReticle"), ("dominantHand", "DominantHand"), ("fireAimMode", "FireAimMode"),
        ("armSwingDirection", "ArmSwingDirection"), ("flatHUDPlacement", "FlatHUDPlacement"),
        ("freeAimShape", "FreeAimShape"), ("freeAimAnchor", "FreeAimAnchor"), ("freeAimPivot", "FreeAimPivot"),
    ]
    for (id, type) in enums {
        guard case .choice(let options) = PresetSchema.byID[id]!.kind else { die("\(id) is a choice") }
        guard let start = settingsText.range(of: "enum \(type):") else { die("enum \(type) exists") }
        let body = settingsText[start.upperBound...].prefix(while: { _ in true }).prefix(900)
        for o in options {
            check(body.contains("case \(o)") || body.contains(", \(o)") || body.contains("\(o),")
                  || body.contains("case \(o),"), "\(type) has a case \(o)")
        }
    }
}

// MARK: Built-in presets

for rt in [false, true] {
for preset in BuiltInPresets.all(rayTracingCapable: rt) {
    check(preset.isBuiltIn, "\(preset.name) is built in")
    check(preset.sanitized.categories == preset.categories,
          "\(preset.name): everything it holds is in the schema, in range and in its category")
    check(!preset.heldCategories.isEmpty, "\(preset.name) holds something")
}
}
check(Set(BuiltInPresets.all(rayTracingCapable: true).map(\.id)).count == 3, "built-in ids are unique")
check(BuiltInPresets.enhanced(rayTracingCapable: false).values(in: .reflections)["waterMirrorMethod"] == .text("rendered"),
      "Enhanced picks the rendered mirror where hardware ray tracing isn't there")
check(BuiltInPresets.enhanced(rayTracingCapable: true).values(in: .reflections)["waterMirrorMethod"] == .text("rayTraced"),
      "Enhanced picks ray tracing on the M5")
check(BuiltInPresets.enhanced(rayTracingCapable: false).values(in: .graphics)["engineMSAA"] == .bool(true)
      && BuiltInPresets.enhanced(rayTracingCapable: false).values(in: .graphics)["fxaaEnabled"] == .bool(true),
      "Enhanced is MSAA with FXAA")

// MARK: File format

do {
    var p = SettingsPreset(name: "Mine", summary: "x", created: Date(timeIntervalSince1970: 1_700_000_000),
                           categories: [.graphics: ["renderScale": .number(0.6), "fxaaEnabled": .bool(false)],
                                        .hands: ["dominantHand": .text("left")]])
    p.id = "abc"
    let data = try p.encoded()
    let back = try SettingsPreset.decode(data)
    check(back == p, "a preset survives a round trip")
    let json = String(decoding: data, as: UTF8.self)
    check(json.contains("\"format\" : \"lambdavision.preset\""), "the file names its format")

    // Unknown settings dropped, out-of-range clamped, wrong types and
    // wrong categories dropped, emptied categories removed.
    let messy = """
    {"format":"lambdavision.preset","version":1,"name":"Messy","categories":{
      "graphics":{"renderScale":7,"gamma":"high","madeUp":true,"fxaaEnabled":true,"glassReflections":true},
      "future":{"x":1},
      "audio":{"sfxVolume":-3,"musicVolume":0.5}}}
    """
    let m = try SettingsPreset.decode(Data(messy.utf8))
    check(m.values(in: .graphics) == ["renderScale": .number(1.0), "fxaaEnabled": .bool(true)],
          "graphics kept clamped scale and fxaa only: \(m.values(in: .graphics))")
    check(m.values(in: .audio) == ["sfxVolume": .number(0), "musicVolume": .number(0.5)], "audio clamped")
    check(m.categories["future"] == nil && m.categories["reflections"] == nil, "unknown and emptied categories removed")
    check(!m.id.isEmpty, "a file without an id gets one")

    func fails(_ s: String, _ e: PresetFileError, _ what: String) {
        do { _ = try SettingsPreset.decode(Data(s.utf8)); die("\(what) should fail") }
        catch let got as PresetFileError { check(got == e, "\(what): wrong error \(got)") }
        catch { die("\(what): not a PresetFileError: \(error)") }
    }
    fails("not json", .notAPreset, "text")
    fails("{\"name\":\"x\",\"categories\":{}}", .notAPreset, "json without a format")
    fails("{\"format\":\"lambdavision.preset\",\"version\":9,\"name\":\"x\",\"categories\":{}}", .newerVersion(9), "newer version")
    fails("{\"format\":\"lambdavision.preset\",\"name\":\"x\",\"categories\":{\"graphics\":{\"nope\":1}}}", .empty, "nothing usable")
}

// MARK: Matching and limiting

do {
    let e = BuiltInPresets.enhanced(rayTracingCapable: true)
    var now: [String: PresetValue] = [:]
    for c in e.heldCategories { for (k, v) in e.values(in: c) { now[k] = v } }
    for c in e.heldCategories { check(e.matches(c, current: now), "\(c) matches itself") }
    check(!e.matches(.audio, current: now), "a category the preset doesn't hold doesn't match")
    now["glassReflections"] = .bool(false)
    check(!e.matches(.reflections, current: now) && e.matches(.graphics, current: now), "one drifted setting breaks only its category")
    now["waterRipples"] = .number(1.0000001)
    check(PresetValue.number(1).matches(.number(1.0000001)), "numbers match within rounding")
    let only = e.limited(to: [.graphics])
    check(only.heldCategories == [.graphics], "limited keeps only the chosen categories")
}

print("preset checks passed")
