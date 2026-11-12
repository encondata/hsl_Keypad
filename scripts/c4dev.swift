// c4dev — talk to an HSL Keypad agent's developer tools from the command line.
//
// Goes through the HSL Toolbar app's developer relay (127.0.0.1:8760; turn it
// on in Settings → Control4 → Developer), which forwards over the app's paired
// connection to the controller. The agent must be a developer build with its
// Developer Mode property On.
//
//   c4dev list                                   paired controllers
//   c4dev [-c NAME] ping
//   c4dev [-c NAME] call FUNCTION [ARG ...]      C4:FUNCTION(ARG, …); each ARG is JSON
//                                                if it parses (123, true, {"a":1}), else a string
//   c4dev [-c NAME] eval 'LUA'                   run Lua on the controller ("-" reads stdin)
//   c4dev [-c NAME] logs [COUNT]                 the agent's recent log lines
//
// NAME is the controller's name, ID or address (default: first connected).

import Foundation
import Network

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var controller: String?
if args.first == "-c" {
    guard args.count >= 2 else { fail("-c needs a controller name") }
    controller = args[1]
    args.removeFirst(2)
}
guard let command = args.first else {
    fail("usage: c4dev [-c NAME] list | ping | call FUNCTION [ARG ...] | eval 'LUA' | logs [COUNT]")
}

func jsonArg(_ text: String) -> Any {
    if let data = text.data(using: .utf8),
       let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        return value
    }
    return text
}

var request: [String: Any] = [:]
switch command {
case "list": request = ["op": "list"]
case "ping": request = ["op": "ping"]
case "call":
    guard args.count >= 2 else { fail("usage: c4dev call FUNCTION [ARG ...]") }
    request = ["op": "call", "fn": args[1], "args": args.dropFirst(2).map(jsonArg)]
case "eval":
    guard args.count >= 2 else { fail("usage: c4dev eval 'LUA' (or - for stdin)") }
    let code = args[1] == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : args[1]
    request = ["op": "eval", "code": code]
case "logs":
    request = ["op": "logs", "count": Int(args.dropFirst().first ?? "100") ?? 100]
default:
    fail("unknown command \(command)")
}
if let controller { request["controller"] = controller }

var line = try JSONSerialization.data(withJSONObject: request)
line.append(0x0A)

let conn = NWConnection(host: "127.0.0.1", port: 8760, using: .tcp)
var reply = Data()
conn.stateUpdateHandler = { state in
    switch state {
    case .ready:
        conn.send(content: line, completion: .contentProcessed { _ in })
    case .waiting, .failed:
        fail("Can't reach the HSL Toolbar developer relay on 127.0.0.1:8760. Turn it on in Settings → Control4 → Developer.")
    default:
        break
    }
}
func receive() {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { data, _, done, error in
        if let data { reply.append(data) }
        if done || error != nil || reply.last == 0x0A {
            if reply.isEmpty {
                fail("Can't reach the HSL Toolbar developer relay on 127.0.0.1:8760. Turn it on in Settings → Control4 → Developer.")
            }
            guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                fail("Unexpected reply: \(String(decoding: reply, as: UTF8.self))")
            }
            // Print printed lines plainly, then the rest as pretty JSON.
            if let printed = object["printed"] as? [String], !printed.isEmpty {
                print(printed.joined(separator: "\n"))
                print("---")
            }
            if let lines = object["lines"] as? [String] {
                print(lines.joined(separator: "\n"))
            } else {
                var rest = object
                rest.removeValue(forKey: "printed")
                rest.removeValue(forKey: "type")
                let pretty = try! JSONSerialization.data(withJSONObject: rest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: pretty, as: UTF8.self))
            }
            exit((object["ok"] as? Bool) == false ? 2 : 0)
        }
        receive()
    }
}
conn.start(queue: .main)
receive()
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fail("Timed out waiting for the agent.") }
dispatchMain()
