//
//  ContentView.swift
//  Sharilka
//
//  Main UI: server controls, status, transfer progress, and log.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = ServerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Main content
            ScrollView {
                VStack(spacing: 16) {
                    serverInfoSection
                    discoverySection
                    transferSection
                    lastTransferSection
                }
                .padding(20)
            }

            Divider()

            // Log
            logSection
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 700, idealHeight: 800)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)

                Text(viewModel.serverState.rawValue)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            // Controls
            HStack(spacing: 10) {
                Button("Start Server") {
                    viewModel.startServer()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!viewModel.canStart)

                Button("Stop Server") {
                    viewModel.stopServer()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!viewModel.canStop)

                Button("Clear") {
                    viewModel.clearStatus()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Server Info

    private var serverInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("TCP Port", value: "\(viewModel.currentPort)")
                infoRow("Save Directory", value: viewModel.saveDirectory)
                    .help(viewModel.saveDirectory)

                if !viewModel.localAddresses.isEmpty {
                    Divider()
                    Text("Local Network Addresses")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.localAddresses, id: \.self) { addr in
                        HStack(spacing: 6) {
                            Image(systemName: "network")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text(addr)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Server", systemImage: "server.rack")
        }
    }

    // MARK: - Discovery

    private var discoverySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Service Type", value: viewModel.bonjourServiceType)
                infoRow("Service Name", value: viewModel.bonjourServiceName.isEmpty ? "(not advertised)" : viewModel.bonjourServiceName)
                infoRow("Protocol Version", value: "\(SharilkaProtocol.version)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Bonjour Discovery", systemImage: "bonjour")
        }
    }

    // MARK: - Transfer Progress

    @ViewBuilder
    private var transferSection: some View {
        if viewModel.serverState == .receiving || viewModel.transferProgress.receivedBytes > 0 {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if !viewModel.transferProgress.fileName.isEmpty {
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.blue)
                            Text(viewModel.transferProgress.fileName)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    // Progress bar
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: viewModel.transferProgress.progressFraction)
                            .progressViewStyle(.linear)

                        HStack {
                            Text("\(formattedBytes(viewModel.transferProgress.receivedBytes)) / \(formattedBytes(viewModel.transferProgress.expectedSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(String(format: "%.1f%%", viewModel.transferProgress.progressPercent))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    }

                    // Speed and ETA
                    HStack(spacing: 20) {
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer")
                                .foregroundStyle(.orange)
                            Text(String(format: "%.1f MB/s", viewModel.transferProgress.speedMBps))
                                .font(.system(.body, design: .monospaced))
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .foregroundStyle(.purple)
                            Text("ETA: \(viewModel.transferProgress.etaFormatted)")
                                .font(.system(.body, design: .monospaced))
                        }

                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Active Transfer", systemImage: "arrow.down.circle.fill")
            }
        }
    }

    // MARK: - Last Transfer

    @ViewBuilder
    private var lastTransferSection: some View {
        if let last = viewModel.lastCompletedTransfer {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("File", value: last.fileName)
                    infoRow("Size", value: last.formattedSize)
                    infoRow("Duration", value: last.formattedDuration)
                    infoRow("Average Speed", value: String(format: "%.1f MB/s", last.averageSpeedMBps))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Last Completed Transfer", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Event Log", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(viewModel.logEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.logEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTimestamp)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 85, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(entry.isError ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.logEntries.count) { _, _ in
                    if let lastEntry = viewModel.logEntries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(height: 180)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch viewModel.serverState {
        case .stopped: return .gray
        case .starting: return .orange
        case .listening: return .green
        case .receiving: return .blue
        case .completed: return .green
        case .error: return .red
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)

            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#Preview {
    ContentView()
}
