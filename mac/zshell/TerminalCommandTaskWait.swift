import Foundation

enum TerminalCommandTaskWait {
    static func wait(
        taskID: String, timeoutMS: Int, connection: AppConnection,
        initialResult: ZshellJSONValue? = nil
    ) throws -> ZshellJSONValue {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMS) * 1_000_000
        var result = initialResult?.objectValue ?? [:]
        repeat {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline > now ? Double(deadline - now) / 1_000_000_000 : 0
            let snapshot = try connection.automationRequest(
                method: "pane.task", params: ["task_id": .string(taskID), "wait": .bool(true)],
                timeout: max(0.1, min(5, remaining))
            )
            guard let task = snapshot.objectValue?["task"]?.objectValue,
                  let state = task["state"]?.stringValue else {
                throw CLIError.message(String(localized: "Zshell returned an invalid command task response."))
            }
            result["task_id"] = .string(taskID)
            result["task"] = .object(task)
            result["waited"] = .bool(true)
            result["timed_out"] = .bool(false)
            if state != "pending" && state != "running" { return .object(result) }
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            Thread.sleep(forTimeInterval: min(0.1, remaining))
        } while true
        result["timed_out"] = .bool(true)
        result["wait_error"] = .object([
            "code": .string("wait_timeout"),
            "message": .string(String(localized: "Timed out waiting for the command. The task can be waited on again.")),
        ])
        return .object(result)
    }

    static func exitCode(for result: ZshellJSONValue) -> Int32 {
        guard let object = result.objectValue,
              object["waited"]?.boolValue == true else { return 0 }
        if object["timed_out"]?.boolValue == true { return 124 }
        guard let task = object["task"]?.objectValue,
              task["state"]?.stringValue == "completed",
              let exitCode = task["exit_code"]?.intValue,
              (0...255).contains(exitCode) else { return 1 }
        return Int32(exitCode)
    }
}
