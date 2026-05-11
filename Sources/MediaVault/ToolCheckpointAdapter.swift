// ToolCheckpointAdapter.swift
// Declares, for each pipeline stage, what kind of pause/resume the underlying
// command-line tool actually supports. This is the policy gate that prevents
// the orchestrator from making promises the tools can't keep.
//
// IMPORTANT ACCURACY NOTES (do not change without re-verifying):
//
//   - `Foundation.Process.suspend()` / `Process.resume()` send `SIGSTOP` /
//     `SIGCONT` to the child. `SIGSTOP` cannot be caught, blocked, or ignored
//     (POSIX `signal(3)` / Apple's `sigaction(2)` man pages), so it reliably
//     halts the child's execution. `SIGCONT` resumes it. These are documented
//     behaviours of POSIX signals on Darwin.
//     Reference: Apple `signal(3)` man page; Apple developer docs for
//     `Process.suspend()`.
//
//   - These signals only affect a running child process whose parent (us) is
//     still alive. If our app exits, our `Process` instance is discarded and
//     the recorded PID is no longer a safe handle (the kernel may reuse it
//     after the child reaps or is reaped). Therefore "pause across an app
//     restart" cannot be implemented by suspending the child and reattaching
//     later.
//
//   - HandBrakeCLI (1.x) has no documented `--resume` or checkpoint flag; the
//     output `.m4v` is finalised only on a clean shutdown. Mid-encode
//     interruption means the encode must restart from frame 0. Reference:
//     https://handbrake.fr/docs/en/latest/cli/command-line-reference.html
//
//   - `makemkvcon` exposes no documented checkpoint/resume flag; rip output
//     is incomplete on interrupt. Reference: makemkv.com forum + binary `--help`.
//
//   - FileBot's `-rename` operates atomically per file (a single `move`
//     syscall on POSIX targets); re-invoking it is safe and idempotent when
//     `--conflict auto` is set. Reference: filebot.net manpage.
//
//   - SublerCli's `-source <file> -optimize` tags the existing `.m4v` in
//     place using atom rewrites; re-running over an already-tagged file
//     produces the same result modulo metadata lookup variance. Reference:
//     Subler wiki on the SublerApp GitHub.
//
// Conclusion: only IN-SESSION pause (SIGSTOP, with the app still running) is
// guaranteed. Cross-restart pause is implemented by recording the job state
// at stage boundaries and requiring the user to acknowledge that the active
// stage will restart from its beginning. This is the policy enforced below.

import Foundation

/// Granularity of pause/resume supported by the underlying tool.
enum ToolCheckpointCapability: String, Sendable {
    /// The tool offers no native checkpointing; the only way to "pause" while
    /// running is `SIGSTOP`, and a process exit means restart from scratch.
    case signalPauseOnly
    /// The stage's effect is fast and idempotent — restarting from the
    /// beginning has no user-visible cost. Pause across restart is effectively
    /// free for this stage.
    case idempotentRestart
}

struct StageCapability: Sendable {
    let stage: PipelineStage
    let capability: ToolCheckpointCapability
    /// Human-readable explanation surfaced in the resume dialog so the user
    /// understands what will happen.
    let resumeBehaviorDescription: String
}

enum ToolCheckpointAdapter {

    /// Lookup table mapping each pipeline stage to its checkpoint capability.
    ///
    /// Keep this table the single source of truth. The orchestrator and the
    /// UI both consult it when deciding what a "pause" or "resume" actually
    /// means for a given job.
    static let table: [PipelineStage: StageCapability] = [
        .ripping: StageCapability(
            stage: .ripping,
            capability: .signalPauseOnly,
            resumeBehaviorDescription:
                "MakeMKV cannot resume a partial rip; this stage will restart from the beginning on resume."
        ),
        .encoding: StageCapability(
            stage: .encoding,
            capability: .signalPauseOnly,
            resumeBehaviorDescription:
                "HandBrakeCLI has no checkpoint format; this stage will restart from frame 0 on resume."
        ),
        .renaming: StageCapability(
            stage: .renaming,
            capability: .idempotentRestart,
            resumeBehaviorDescription:
                "FileBot rename is idempotent; resuming re-runs it cheaply."
        ),
        .fileBotScript: StageCapability(
            stage: .fileBotScript,
            capability: .idempotentRestart,
            resumeBehaviorDescription:
                "FileBot script runs are idempotent; resuming re-runs them cheaply."
        ),
        .tagging: StageCapability(
            stage: .tagging,
            capability: .idempotentRestart,
            resumeBehaviorDescription:
                "Subler tagging is idempotent; resuming re-runs it cheaply."
        )
    ]

    /// Returns the capability for `stage`, or a safe default when the stage
    /// isn't in the table (idle/done/failed have no meaningful checkpoint).
    static func capability(for stage: PipelineStage) -> StageCapability {
        if let value = table[stage] { return value }
        return StageCapability(
            stage: stage,
            capability: .idempotentRestart,
            resumeBehaviorDescription: "No active work to resume."
        )
    }

    /// True if pausing across a restart will lose mid-stage progress on this
    /// stage (used to drive the warning in the resume dialog).
    static func resumeWillRestartStage(_ stage: PipelineStage) -> Bool {
        switch capability(for: stage).capability {
        case .signalPauseOnly:    return true
        case .idempotentRestart:  return false
        }
    }
}
