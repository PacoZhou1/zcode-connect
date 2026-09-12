import SwiftUI

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
    @State private var roots: [RemoteFile] = []
    @State private var children: [String: [RemoteFile]] = [:]
    @State private var loadingFolders: Set<String> = []
    private var projectID: String { store.session(sessionID)?.projectID ?? "" }
    private struct FileRow: Identifiable {
        var id: String { file.id }
        var file: RemoteFile
        var depth: Int
    }
    private var rows: [FileRow] {
        if !store.isReferenceMode, !search.isEmpty {
            return (searchResults ?? []).map { FileRow(file: $0, depth: 0) }
        }
        func visit(_ files: [RemoteFile], depth: Int) -> [FileRow] {
            files.flatMap { file -> [FileRow] in
                let descendants = children[file.path] ?? file.children ?? []
                let subrows = visit(descendants, depth: depth + 1)
                let visible = search.isEmpty || file.name.localizedStandardContains(search) || !subrows.isEmpty
                guard visible else { return [] }
                return [FileRow(file: file, depth: depth)] +
                    ((expanded.contains(file.id) || !search.isEmpty) ? subrows : [])
            }
        }
        return visit(roots, depth: 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("文件范围", selection: $modified) {
                    Text("已修改").tag(true)
                    Text("所有文件").tag(false)
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 7.666667)
                    .accessibilityIdentifier("files.filter")
                Divider()
                if loading {
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
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 20, weight: .medium)) }
                        .accessibilityLabel("关闭文件").accessibilityIdentifier("files.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassSearchField(text: $search, placeholder: "搜索文件")
                    .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, -5.333333)
            }
            .navigationDestination(item: $selectedFile) { file in
                FilePreviewView(file: file, projectID: projectID)
            }
            .navigationDestination(item: $selectedChange) { change in
                DiffView(change: change)
            }
        }
        .tint(.primary)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { modified = initiallyModified; await load() }
        .task(id: search) {
            guard !store.isReferenceMode else { return }
            searchResults = nil; searchIncomplete = false; searchFailure = nil
            guard !search.isEmpty else { searching = false; return }
            searching = true
            let query = search
            do {
                try await Task.sleep(for: .milliseconds(250))
                let response = try await store.searchFiles(projectID: projectID, query: query)
                guard !Task.isCancelled, query == search else { return }
                searchResults = response.files.map(\.local)
                searchIncomplete = response.truncated == true || response.searchComplete == false
            } catch {
                guard !Task.isCancelled, query == search else { return }
                searchFailure = error.localizedDescription
            }
            if !Task.isCancelled { searching = false }
        }
    }

    private var allFilesList: some View {
        Group {
            if searching {
                ProgressView("搜索项目文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchFailure {
                ContentUnavailableView("搜索失败", systemImage: "magnifyingglass", description: Text(searchFailure))
            } else if !rows.isEmpty {
                List {
                    if searchIncomplete {
                        Text("仅显示部分结果，请用更具体的文件名继续搜索。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        fileRow(row.file, depth: row.depth)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
            } else {
                ContentUnavailableView(search.isEmpty ? "这个文件夹为空" : "没有找到文件", systemImage: "folder",
                    description: Text(search.isEmpty ? "项目中的文件会显示在这里。" :
                                      searchIncomplete ? "搜索未完成，请缩小范围后重试。" : "试试其他文件名。"))
            }
        }
    }

    private var modifiedList: some View {
        Group {
            let filtered = changes.filter { search.isEmpty || $0.path.localizedStandardContains(search) }
            if filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "没有文件变更" : "没有找到文件", systemImage: "doc.text.magnifyingglass",
                    description: Text(search.isEmpty ? "任务修改文件后，变更会显示在这里。" : "试试其他文件名。"))
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
                    if file.isDirectory {
                        if expanded.contains(file.id) { expanded.remove(file.id) }
                        else {
                            expanded.insert(file.id)
                            if !store.isReferenceMode, children[file.path] == nil {
                                loadingFolders.insert(file.path)
                                Task {
                                    defer { loadingFolders.remove(file.path) }
                                    do { children[file.path] = try await store.files(projectID: projectID, path: file.path) }
                                    catch { store.errorMessage = error.localizedDescription; expanded.remove(file.id) }
                                }
                            }
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
    private func load() async {
        loading = true
        failure = nil
        changesFailure = nil
        defer { loading = false }
        do {
            roots = try await store.files(projectID: projectID)
        }
        catch { failure = error.localizedDescription }
        do {
            let summary = try await store.changeSummary(sessionID)
            changes = summary.files
            changesSource = summary.source
            changesTruncated = summary.truncated == true
        } catch { changesFailure = error.localizedDescription }
    }
}

struct FilePreviewView: View {
    @Environment(AppStore.self) private var store
    let file: RemoteFile
    var projectID: String = ""
    @State private var content: String?
    @State private var error: String?
    var body: some View {
        Group {
            if let error { ContentUnavailableView("无法预览", systemImage: "doc", description: Text(error)) }
            else if let content {
                ScrollView([.horizontal, .vertical]) {
                    Text(content.isEmpty ? "空文件" : content)
                .font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ProgressView() }
        }.navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.copy(content ?? "") } label: { Image(systemName: "square.on.square") }
                        .accessibilityLabel("复制文件内容")
                        .disabled(content == nil)
                }
            }
            .task {
                if store.isReferenceMode { content = file.content ?? "" }
                else {
                    do { content = try await store.fileContent(projectID: projectID, path: file.path) }
                    catch { self.error = error.localizedDescription }
                }
            }
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
        .navigationTitle(URL(fileURLWithPath: change.path).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.copy(change.diff) } label: { Image(systemName: "square.on.square") }
                    .accessibilityLabel("复制变更")
            }
        }
    }
}
