// RunControlView.swift
// Reusable pause / resume / stop control cluster. Three scopes are supported
// through a single view: global, lane, and per-job. The Stop button always
// shows a confirmation dialog before destructive action.

import SwiftUI

/// Scope determines which orchestrator method the buttons call.
enum RunControlScope: Equatable {
    case global
    case lane(PipelineLane)
    case job(ConversionJobID, lane: PipelineLane, lifecycle: JobLifecycleState)
}

struct RunControlView: View {
    @EnvironmentObject private var pipeline: PipelineController
    let scope: RunControlScope
    /// Compact mode shows icon-only buttons for embedding in queue rows.
    var compact: Bool = false

    @State private var showStopConfirmation: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            pauseOrResumeButton
            stopButton
        }
        .confirmationDialog(
            stopConfirmationTitle,
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { performStop() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(stopConfirmationMessage)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var pauseOrResumeButton: some View {
        let pausedFlag = isPaused
        Group {
            if compact {
                Button {
                    pausedFlag ? performResume() : performPause()
                } label: {
                    Image(systemName: pausedFlag ? "play.circle" : "pause.circle")
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button {
                    pausedFlag ? performResume() : performPause()
                } label: {
                    Label(pausedFlag ? "Resume" : "Pause",
                          systemImage: pausedFlag ? "play.circle" : "pause.circle")
                }
                .buttonStyle(DefaultButtonStyle())
            }
        }
        .disabled(!canPauseOrResume)
        .help(pausedFlag ? "Resume" : "Pause")
    }

    @ViewBuilder
    private var stopButton: some View {
        Group {
            if compact {
                Button {
                    showStopConfirmation = true
                } label: {
                    Image(systemName: "stop.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button {
                    showStopConfirmation = true
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(DefaultButtonStyle())
            }
        }
        .disabled(!canStop)
        .help("Stop and discard progress")
    }

    // MARK: - Scope-aware state

    private var isPaused: Bool {
        switch scope {
        case .global:
            return pipeline.items.contains { isPausedState($0.lifecycle) }
                && !pipeline.items.contains { $0.lifecycle == .running }
        case .lane(let lane):
            let laneItems = pipeline.items(on: lane)
            guard !laneItems.isEmpty else { return false }
            return laneItems.allSatisfy { isPausedState($0.lifecycle) || isTerminal($0.lifecycle) }
        case .job(_, _, let lifecycle):
            return isPausedState(lifecycle)
        }
    }

    private var canPauseOrResume: Bool {
        switch scope {
        case .global:
            return pipeline.items.contains { !isTerminal($0.lifecycle) }
        case .lane(let lane):
            return pipeline.items(on: lane).contains { !isTerminal($0.lifecycle) }
        case .job(_, _, let lifecycle):
            return !isTerminal(lifecycle)
        }
    }

    private var canStop: Bool {
        switch scope {
        case .global:
            return pipeline.items.contains { !isTerminal($0.lifecycle) }
        case .lane(let lane):
            return pipeline.items(on: lane).contains { !isTerminal($0.lifecycle) }
        case .job(_, _, let lifecycle):
            return !isTerminal(lifecycle)
        }
    }

    // MARK: - Confirmation copy

    private var stopConfirmationTitle: String {
        switch scope {
        case .global:        return "Stop all conversions?"
        case .lane(let lane): return "Stop \(lane.rawValue) lane?"
        case .job:           return "Stop this conversion?"
        }
    }

    private var stopConfirmationMessage: String {
        let header = "All matching active processes will be terminated immediately."
        let body = "Any in-flight stage (encoding, ripping, tagging, etc.) will need to be restarted from the beginning. Completed stages are preserved."
        let scopeQualifier: String
        switch scope {
        case .global:
            scopeQualifier = "This affects every queued, running and paused job in both the File and Disc lanes."
        case .lane(let lane):
            scopeQualifier = "This affects every job in the \(lane.rawValue) lane."
        case .job:
            scopeQualifier = "This affects only this single conversion."
        }
        return "\(header) \(scopeQualifier)\n\n\(body)"
    }

    // MARK: - Actions

    private func performPause() {
        switch scope {
        case .global:                      pipeline.pauseAll()
        case .lane(let lane):              pipeline.pauseLane(lane)
        case .job(let id, _, _):           pipeline.pauseJob(id)
        }
    }

    private func performResume() {
        switch scope {
        case .global:                      pipeline.resumeAll()
        case .lane(let lane):              pipeline.resumeLane(lane)
        case .job(let id, _, _):           pipeline.resumeJob(id)
        }
    }

    private func performStop() {
        switch scope {
        case .global:                      pipeline.stopAll()
        case .lane(let lane):              pipeline.stopLane(lane)
        case .job(let id, _, _):           pipeline.stopJob(id)
        }
    }

    // MARK: - Lifecycle helpers

    private func isPausedState(_ s: JobLifecycleState) -> Bool {
        s == .paused || s == .pausing
    }

    private func isTerminal(_ s: JobLifecycleState) -> Bool {
        s == .completed || s == .failed || s == .stopped
    }
}
