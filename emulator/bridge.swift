// Runs the HSL Keypad agent's Lua on a Mac behind a real TCP port, so the
// HSL Toolbar app can pair with and control the actual agent code.
//
//   swift Control4/emulator/bridge.swift [luajit path] [emulator.lua path]
//
// The Lua side (emulator.lua) talks to this bridge over stdin/stdout, one
// line per message:
//   Lua → bridge:  LISTEN <port> | SEND <handle> <json string> | CLOSE <handle>
//                  TIMER <id> <ms> | CANCEL <id> | LOG <text>
//   bridge → Lua:  CONNECT <handle> <address> | DATA <handle> <json string>
//                  DISCONNECT <handle> | FIRE <id> | CONSOLE <text>
// Lines typed into this program's stdin are forwarded as CONSOLE commands
// (e.g. "level 345 40", "rename 345 Island", "help").

import Foundation
import Network

let args = CommandLine.arguments
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let luajit = args.count > 1 ? args[1] : "/opt/homebrew/bin/luajit"
let script = args.count > 2 ? args[2] : here.appending(path: "emulator.lua").path

let lua = Process()
lua.executableURL = URL(fileURLWithPath: luajit)
lua.arguments = [script]
lua.currentDirectoryURL = here
let toLua = Pipe(), fromLua = Pipe()
lua.standardInput = toLua
lua.standardOutput = fromLua
lua.standardError = FileHandle.standardError

let queue = DispatchQueue(label: "bridge")
var listener: NWListener?
var connections: [Int: NWConnection] = [:]
var timers: [String: DispatchSourceTimer] = [:]
var nextHandle = 1

func toLuaLine(_ line: String) {
    toLua.fileHandleForWriting.write(Data((line + "\n").utf8))
}

func jsonString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let text = String(decoding: data, as: UTF8.self)
    return String(text.dropFirst().dropLast())  // strip [ ]
}

func decodeJSONString(_ s: String) -> String? {
    guard let data = "[\(s)]".data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
    return array.first
}

func receive(_ handle: Int, _ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
        queue.async {
            if let data, !data.isEmpty { toLuaLine("DATA \(handle) \(jsonString(String(decoding: data, as: UTF8.self)))") }
            if done || error != nil {
                if connections.removeValue(forKey: handle) != nil { toLuaLine("DISCONNECT \(handle)") }
                conn.cancel()
            } else {
                receive(handle, conn)
            }
        }
    }
}

func listen(_ port: UInt16) {
    guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else {
        FileHandle.standardError.write(Data("bridge: can't listen on \(port)\n".utf8))
        return
    }
    l.newConnectionHandler = { conn in
        queue.async {
            let handle = nextHandle
            nextHandle += 1
            connections[handle] = conn
            conn.start(queue: queue)
            var address = "unknown"
            if case .hostPort(let host, _) = conn.endpoint { address = "\(host)" }
            toLuaLine("CONNECT \(handle) \(address)")
            receive(handle, conn)
        }
    }
    l.start(queue: queue)
    listener = l
    print("bridge: agent listening on port \(port)")
}

func handleLuaLine(_ line: String) {
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    switch parts.first {
    case "LISTEN":
        if parts.count > 1, let port = UInt16(parts[1]) { listen(port) }
    case "SEND":
        guard parts.count > 2, let handle = Int(parts[1]), let text = decodeJSONString(parts[2]) else { return }
        connections[handle]?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    case "CLOSE":
        guard parts.count > 1, let handle = Int(parts[1]), let conn = connections.removeValue(forKey: handle) else { return }
        conn.cancel()
    case "TIMER":
        guard parts.count > 2, let ms = Int(parts[2]) else { return }
        let id = parts[1]
        timers[id]?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(ms))
        t.setEventHandler {
            timers[id] = nil
            toLuaLine("FIRE \(id)")
        }
        t.resume()
        timers[id] = t
    case "CANCEL":
        if parts.count > 1 { timers.removeValue(forKey: parts[1])?.cancel() }
    case "LOG":
        print("agent: " + parts.dropFirst().joined(separator: " "))
    default:
        print("lua: " + line)
    }
}

// Lua stdout → bridge, line by line.
var luaBuffer = Data()
fromLua.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    queue.async {
        if chunk.isEmpty { return }
        luaBuffer.append(chunk)
        while let nl = luaBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: luaBuffer[luaBuffer.startIndex..<nl], as: UTF8.self)
            luaBuffer.removeSubrange(luaBuffer.startIndex...nl)
            handleLuaLine(line)
        }
    }
}

// Typed console commands → Lua.
FileHandle.standardInput.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else {  // console closed: stop reading, keep running
        handle.readabilityHandler = nil
        return
    }
    let text = String(decoding: data, as: UTF8.self)
    queue.async {
        for line in text.split(separator: "\n") where !line.isEmpty { toLuaLine("CONSOLE \(line)") }
    }
}

lua.terminationHandler = { p in
    print("bridge: agent exited (\(p.terminationStatus))")
    exit(p.terminationStatus)
}

try lua.run()
setvbuf(stdout, nil, _IOLBF, 0)
dispatchMain()
