import SwiftUI

struct FileTreeRow: Identifiable {
    var id: String { file.id }
    var file: RemoteFile
    var depth: Int
}

enum FileTreeProjection {
    static func rows(roots: [RemoteFile], expanded: Set<String>, search: String,
                     children: (RemoteFile) -> [RemoteFile]) -> [FileTreeRow] {
        var result: [FileTreeRow] = []
        var visited: Set<String> = []
        func visit(_ files: [RemoteFile], depth: Int) {
            for file in files where visited.insert(file.id).inserted {
                let start = result.count
                result.append(FileTreeRow(file: file, depth: depth))
                if !search.isEmpty || expanded.contains(file.id) {
                    visit(children(file), depth: depth + 1)
                }
                if !search.isEmpty, !file.name.localizedStandardContains(search), result.count == start + 1 {
                    result.removeLast()
                }
            }
        }
        visit(roots, depth: 0)
        return result
    }
}

struct FileBrowserIdentity: Equatable {
    var generation: UUID
    var sessionID: String
    var projectID: String
    var reference: Bool
    var online: Bool
    var sessionSource: String?
    var supportsChanges: Bool { !["bridge-subagent", "official-relay-subagent"].contains(sessionSource ?? "") }
}

struct FilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    var initiallyModified: Bool
    @State private var modified = false
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var changes: [FileChange] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var changesFailure: String?
    @State private var searchFailure: String?
    @State private var searchResults: [RemoteFile]?
    @State private var searchIncomplete = false
    @State private var searching = false
    @State private var changesSource: String?
    @State private var changesTruncated = false
    @State private var selectedFile: RemoteFile?
    @State private var selectedChange: FileChange?
    @State private var rootListing = RemoteFileListing(files: [])
    @State private var children: [String: RemoteFileListing] = [:]
    @State private var loadingFolders: Set<String> = []
    @State private var folderFailures: [String: String] = [:]
    @State private var folderRequests: [String: UUID] = [:]
    @State private var rootRequest = UUID()
    @State private var searchRequest = UUID()
    @State private var loadedIdentity: FileBrowserIdentity?
    @State private var configured = false
    private var projectID: String { store.session(sessionID)?.projectID ?? "" }
    private var identity: FileBrowserIdentity {
        FileBrowserIdentity(generation: store.fileListingGeneration, sessionID: sessionID, projectID: projectID,
                            reference: store.isReferenceMode, online: store.connection.isOnline,
                            sessionSource: store.session(sessionID)?.source)
    }
    private struct SearchIdentity: Equatable {
        var source: FileBrowserIdentity
        var rootRequest: UUID
        var query: String
        var modified: Bool
        var ready: Bool
    }
    private var searchIdentity: SearchIdentity {
        SearchIdentity(source: identity, rootRequest: rootRequest, query: search, modified: modified,
                       ready: loadedIdentity == identity && !loading)
    }
    private var rows: [FileTreeRow] {
        if !store.isReferenceMode, !search.isEmpty {
            return (searchResults ?? []).map { FileTreeRow(file: $0, depth: 0) }
        }
        return FileTreeProjection.rows(roots: rootListing.files, expanded: expanded, search: search) {
            children[$0.path]?.files ?? $0.children ?? []
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if identity.supportsChanges {
                    Picker("文件范围", selection: $modified) {
                        Text("已修改").tag(true)
                        Text("所有文件").tag(false)
                    }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 11.666667)
                        .accessibilityIdentifier("files.filter")
                    Divider()
                }
                if loading || loadedIdentity != identity {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = modified ? changesFailure : failure {
                    ContentUnavailableView("无法读取文件", systemImage: "wifi.exclamationmark", description: Text(error))
                        .overlay(alignment: .bottom) { Button("重试") { Task { await load() } }.buttonStyle(NativeGlassButtonStyle()).padding(30) }
                } else if modified {
                    modifiedList
                } else {
                    allFilesList
                }
            }
            .navigationTitle("文件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)) }
                        .accessibilityLabel("关闭文件").accessibilityIdentifier("files.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassSearchField(text: $search, placeholder: "搜索文件")
                    .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, -5.333333)
            }
            .navigationDestination(item: $selectedFile) { file in
                FilePreviewView(file: file, source: loadedIdentity ?? identity)
            }
            .navigationDestination(item: $selectedChange) { change in
                DiffView(change: change)
            }
        }
        .tint(.primary)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task(id: identity) {
            if !configured { modified = initiallyModified; configured = true }
            await load()
        }
        .task(id: searchIdentity) { await runSearch() }
        .onDisappear {
            rootRequest = UUID(); searchRequest = UUID()
            folderRequests = [:]; loadingFolders = []
        }
    }

    private var allFilesList: some View {
        Group {
            let visibleRows = rows
            if searching {
                ProgressView("搜索项目文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchFailure {
                ContentUnavailableView("搜索失败", systemImage: "magnifyingglass", description: Text(searchFailure))
            } else if !visibleRows.isEmpty {
                List {
                    if search.isEmpty && rootListing.truncated {
                        Text("这个目录仅显示部分内容，请用更具体的文件名搜索项目。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("files.root.truncated")
                    } else if searchIncomplete {
                        Text("仅显示部分结果，请用更具体的文件名继续搜索。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(visibleRows) { row in
                        fileRow(row.file, depth: row.depth)
                        if row.file.isDirectory && expanded.contains(row.file.id) {
                            directoryFeedback(row.file, depth: row.depth)
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
            } else {
                let incomplete = search.isEmpty ? rootListing.truncated : searchIncomplete
                ContentUnavailableView(incomplete ? (search.isEmpty ? "目录结果不完整" : "搜索结果不完整") :
                                        (search.isEmpty ? "这个文件夹为空" : "没有找到文件"), systemImage: "folder",
                    description: Text(incomplete ? "电脑只返回了部分结果，请用更具体的文件名搜索项目。" :
                                      search.isEmpty ? "项目中的文件会显示在这里。" : "试试其他文件名。"))
            }
        }
    }

    private var modifiedList: some View {
        Group {
            let filtered = changes.filter { search.isEmpty || $0.path.localizedStandardContains(search) }
            if filtered.isEmpty {
                ContentUnavailableView(changesTruncated ? "变更结果不完整" : (search.isEmpty ? "没有文件变更" : "没有找到文件"), systemImage: "doc.text.magnifyingglass",
                    description: Text(changesTruncated ? "电脑仅返回了部分变更，请在电脑上查看完整结果。" :
                                      search.isEmpty ? "任务修改文件后，变更会显示在这里。" : "试试其他文件名。"))
            } else {
                List {
                    if changesSource == "workspace" || changesSource == "workspace-git-unstaged" {
                        Text("当前项目的工作区变更，可能包含其他任务或你手动编辑的内容。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if changesTruncated {
                        Text("变更较多，当前仅显示部分内容。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { change in
                    Button { selectedChange = change } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(change.path).font(.system(size: 15)).lineLimit(2)
                            Spacer()
                            ChangeCount(additions: change.additions, deletions: change.deletions)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    }
                }.listStyle(.plain)
            }
        }
    }

    private func fileRow(_ file: RemoteFile, depth: Int) -> some View {
                Button {
                    guard loadedIdentity == identity else { return }
                    if file.isDirectory {
                        if expanded.contains(file.id) { expanded.remove(file.id) }
                        else {
                            expanded.insert(file.id)
                            loadChildren(file)
                        }
                    } else { selectedFile = file }
                } label: {
                    HStack(spacing: 10) {
                        if file.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .medium))
                                .rotationEffect(.degrees(expanded.contains(file.id) || !search.isEmpty ? 90 : 0))
                                .frame(width: 12)
                        } else { Color.clear.frame(width: 12, height: 1) }
                        Group {
                            if file.isDirectory {
                                FolderGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                    .frame(width: 18, height: 18)
                            } else { Image(systemName: "doc.text").font(.system(size: 18)) }
                        }.frame(width: 22)
                        Text(file.name).font(.system(size: 17)).foregroundStyle(Color.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        if loadingFolders.contains(file.path) { ProgressView().controlSize(.mini) }
                    }.foregroundStyle(.secondary).padding(.leading, CGFloat(depth) * 16)
                        .frame(height: 34.333333).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .overlay(alignment: .bottom) {
                        Color(uiColor: .separator).frame(height: 1 / 3).padding(.leading, 34).padding(.trailing, -16).offset(y: 4)
                    }
    }

    @ViewBuilder private func directoryFeedback(_ file: RemoteFile, depth: Int) -> some View {
        if let error = folderFailures[file.path] {
            VStack(alignment: .leading, spacing: 6) {
                Text("无法读取此文件夹：\(error)")
                Button("重试") { loadChildren(file) }
            }.font(.footnote).foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth + 1) * 16)
        } else if children[file.path]?.truncated == true {
            Text("\(file.name) 仅显示部分内容，可搜索项目中的文件名。")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth + 1) * 16)
                .accessibilityIdentifier("files.directory.truncated.\(file.path)")
        }
    }

    private func isCurrent(_ source: FileBrowserIdentity, request: UUID) -> Bool {
        !Task.isCancelled && source == identity && loadedIdentity == source && rootRequest == request
    }

    private func loadChildren(_ file: RemoteFile) {
        let source = identity, root = rootRequest
        guard !source.reference, loadedIdentity == source, children[file.path] == nil,
              folderRequests[file.path] == nil else { return }
        let request = UUID()
        folderRequests[file.path] = request; loadingFolders.insert(file.path); folderFailures[file.path] = nil
        Task {
            defer {
                if isCurrent(source, request: root), folderRequests[file.path] == request {
                    folderRequests[file.path] = nil; loadingFolders.remove(file.path)
                }
            }
            guard isCurrent(source, request: root) else { return }
            do {
                let listing = try await store.fileListing(projectID: source.projectID, path: file.path)
                guard isCurrent(source, request: root), folderRequests[file.path] == request else { return }
                children[file.path] = listing
            } catch is CancellationError { return }
            catch {
                guard isCurrent(source, request: root), folderRequests[file.path] == request else { return }
                folderFailures[file.path] = error.localizedDescription
            }
        }
    }

    private func runSearch() async {
        let source = searchIdentity, request = UUID()
        searchRequest = request
        searchResults = nil; searchIncomplete = false; searchFailure = nil; searching = false
        guard source.ready, !source.source.reference, !source.modified, !source.query.isEmpty else { return }
        searching = true
        defer { if searchRequest == request, searchIdentity == source { searching = false } }
        do {
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, searchRequest == request, searchIdentity == source else { return }
            let response = try await store.searchFiles(projectID: source.source.projectID, query: source.query)
            guard !Task.isCancelled, searchRequest == request, searchIdentity == source else { return }
            searchResults = response.files.map(\.local)
            searchIncomplete = response.truncated == true || response.searchComplete == false
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, searchRequest == request, searchIdentity == source else { return }
            searchFailure = error.localizedDescription
        }
    }

    private func load() async {
        let source = identity, request = UUID()
        if !source.supportsChanges { modified = false }
        rootRequest = request; loadedIdentity = source
        rootListing = RemoteFileListing(files: []); children = [:]; expanded = []
        loadingFolders = []; folderRequests = [:]; folderFailures = [:]
        changes = []; changesSource = nil; changesTruncated = false
        selectedFile = nil; selectedChange = nil
        loading = true
        failure = nil
        changesFailure = nil
        searchRequest = UUID(); searchResults = nil; searchIncomplete = false; searchFailure = nil; searching = false
        defer { if isCurrent(source, request: request) { loading = false } }
        do {
            let listing = try await store.fileListing(projectID: source.projectID)
            guard isCurrent(source, request: request) else { return }
            rootListing = listing
        }
        catch is CancellationError { return }
        catch { guard isCurrent(source, request: request) else { return }; failure = error.localizedDescription }
        guard isCurrent(source, request: request), source.supportsChanges else { return }
        do {
            let summary = try await store.changeSummary(source.sessionID)
            guard isCurrent(source, request: request) else { return }
            changes = summary.files
            changesSource = summary.source
            changesTruncated = summary.truncated == true
        } catch is CancellationError { return }
        catch { guard isCurrent(source, request: request) else { return }; changesFailure = error.localizedDescription }
    }
}

struct FilePreviewView: View {
    @Environment(AppStore.self) private var store
    let file: RemoteFile
    let source: FileBrowserIdentity
    @State private var content: String?
    @State private var error: String?
    @State private var request = UUID()
    private var identity: FileBrowserIdentity {
        FileBrowserIdentity(generation: store.fileListingGeneration, sessionID: source.sessionID,
                            projectID: store.session(source.sessionID)?.projectID ?? "",
                            reference: store.isReferenceMode, online: store.connection.isOnline,
                            sessionSource: store.session(source.sessionID)?.source)
    }
    var body: some View {
        Group {
            if source != identity {
                ContentUnavailableView("连接已切换", systemImage: "desktopcomputer", description: Text("请返回文件列表重新选择文件。"))
            } else if let error { ContentUnavailableView("无法预览", systemImage: "doc", description: Text(error)) }
            else if let content {
                ScrollView([.horizontal, .vertical]) {
                    Text(content.isEmpty ? "空文件" : content)
                .font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }.defaultScrollAnchor(.topLeading)
            } else { ProgressView() }
        }.navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { if source == identity { store.copy(content ?? "") } } label: { Image(systemName: "square.on.square") }
                        .accessibilityLabel("复制文件内容")
                        .disabled(content == nil || source != identity)
                }
            }
            .task(id: source) {
                let current = UUID(); request = current
                content = nil; error = nil
                guard source == identity else { return }
                if source.reference { content = file.content ?? "" }
                else {
                    do {
                        let value = try await store.fileContent(projectID: source.projectID, path: file.path)
                        guard !Task.isCancelled, request == current, source == identity else { return }
                        content = value
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled, request == current, source == identity else { return }
                        self.error = error.localizedDescription
                    }
                }
            }
            .onDisappear { request = UUID() }
    }
}

struct DiffView: View {
    @Environment(AppStore.self) private var store
    let change: FileChange
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                if change.truncated == true {
                    Text("此文件的差异过长，预览未显示全部内容。").font(.footnote).foregroundStyle(.secondary).padding(12)
                }
                ForEach(Array(change.diff.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                        Text(line.isEmpty ? " " : line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, design: .monospaced)).padding(.vertical, 3).padding(.horizontal, 12)
                    .background(line.hasPrefix("+") ? Color.green.opacity(0.1) : line.hasPrefix("-") ? Color.red.opacity(0.1) : Color.clear)
                }
            }.padding(.vertical, 12)
        }
        .defaultScrollAnchor(.topLeading)
        .navigationTitle(URL(fileURLWithPath: change.path).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.copy(change.diff) } label: { Image(systemName: "square.on.square") }
                    .accessibilityLabel("复制变更")
            }
        }
    }
}
