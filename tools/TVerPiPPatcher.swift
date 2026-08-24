#!/usr/bin/env swift

import Foundation

private let expectedBundleID = "jp.hamitv.hamitvapp1"
private let machMagic64: UInt32 = 0xfeedfacf
private let loadDylibCommand: UInt32 = 0x0c

private enum PatchError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

private extension Data {
    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw PatchError.message("unexpected end of file at offset \(offset)")
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func setUInt32LE(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0, offset + 4 <= count else {
            throw PatchError.message("unexpected end of file at offset \(offset)")
        }
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private func patchInfoPlist(at path: String) throws {
    let url = URL(fileURLWithPath: path)
    let source = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.binary
    let object = try PropertyListSerialization.propertyList(from: source, options: [], format: &format)
    guard var info = object as? [String: Any] else {
        throw PatchError.message("Info.plist root is not a dictionary")
    }
    guard info["CFBundleIdentifier"] as? String == expectedBundleID else {
        throw PatchError.message("unexpected bundle identifier: \(info["CFBundleIdentifier"] ?? "nil")")
    }

    var modes = info["UIBackgroundModes"] as? [String] ?? []
    if !modes.contains("audio") { modes.append("audio") }
    info["UIBackgroundModes"] = modes
    info.removeValue(forKey: "UISupportedDevices")

    let output = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .binary,
        options: 0
    )
    try output.write(to: url)
}

private func addLoadDylib(to path: String, installName: String) throws {
    let url = URL(fileURLWithPath: path)
    var data = try Data(contentsOf: url)
    guard try data.uint32LE(at: 0) == machMagic64 else {
        throw PatchError.message("only thin little-endian 64-bit Mach-O files are supported")
    }

    let commandCount = Int(try data.uint32LE(at: 16))
    let commandsSize = Int(try data.uint32LE(at: 20))
    var offset = 32

    for _ in 0..<commandCount {
        let command = try data.uint32LE(at: offset)
        let commandSize = Int(try data.uint32LE(at: offset + 4))
        guard commandSize >= 8, offset + commandSize <= data.count else {
            throw PatchError.message("invalid Mach-O load command at offset \(offset)")
        }
        if command == loadDylibCommand {
            let nameOffset = Int(try data.uint32LE(at: offset + 8))
            guard nameOffset < commandSize else {
                throw PatchError.message("invalid dylib name offset")
            }
            let nameBytes = data[(offset + nameOffset)..<(offset + commandSize)]
            let existing = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            if existing == installName {
                print("load command already present")
                return
            }
        }
        offset += commandSize
    }

    var name = Data(installName.utf8)
    name.append(0)
    let commandSize = (24 + name.count + 7) & ~7
    let insertOffset = 32 + commandsSize
    guard insertOffset + commandSize <= data.count else {
        throw PatchError.message("Mach-O header has insufficient padding")
    }
    guard data[insertOffset..<(insertOffset + commandSize)].allSatisfy({ $0 == 0 }) else {
        throw PatchError.message("Mach-O header has insufficient zero-filled padding")
    }

    var newCommand = Data()
    newCommand.appendUInt32LE(loadDylibCommand)
    newCommand.appendUInt32LE(UInt32(commandSize))
    newCommand.appendUInt32LE(24)
    newCommand.appendUInt32LE(0)
    newCommand.appendUInt32LE(0)
    newCommand.appendUInt32LE(0)
    newCommand.append(name)
    newCommand.append(Data(repeating: 0, count: commandSize - newCommand.count))
    data.replaceSubrange(insertOffset..<(insertOffset + commandSize), with: newCommand)
    try data.setUInt32LE(UInt32(commandCount + 1), at: 16)
    try data.setUInt32LE(UInt32(commandsSize + commandSize), at: 20)
    try data.write(to: url)
    print("added \(installName)")
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw PatchError.message("usage: TVerPiPPatcher.swift <patch-info|add-load-dylib> ...")
    }
    switch command {
    case "patch-info" where arguments.count == 2:
        try patchInfoPlist(at: arguments[1])
    case "add-load-dylib" where arguments.count == 3:
        try addLoadDylib(to: arguments[1], installName: arguments[2])
    default:
        throw PatchError.message("invalid arguments")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
