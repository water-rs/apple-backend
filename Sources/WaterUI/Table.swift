import CWaterUI
import SwiftUI

@MainActor
struct WuiTable: WuiComponent, View {
    static let id: String = decodeViewIdentifier(waterui_table_id())
    let env: WuiEnvironment

    private var columns: WuiComputed<[WuiTableColumn]>

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        fatalError()
    }

    init(table: CWaterUI.WuiTable, env: WuiEnvironment) {
        self.columns = WuiComputed<[WuiTableColumn]>(table.columns)
        self.env = env
    }

    var body: some View {
        fatalError("SwiftUI's table is static and cannot handle dynamic columns yet.")
    }
}

@MainActor
struct WuiTableColumn: Identifiable {
    var id = UUID()
    static let id: String = decodeViewIdentifier(waterui_table_column_id())
    @State var label: WuiComputed<WuiStyledStr>
    var contents: WuiAnyViews
    init(column: CWaterUI.WuiTableColumn) {
        self.label = WuiComputed<WuiStyledStr>(column.label.content)
        self.contents = WuiAnyViews(column.rows)
    }

    init(anyview: OpaquePointer) {
        self.init(column: waterui_force_as_table_column(anyview))
    }

}

extension WuiComputed where T == [WuiTableColumn] {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: { inner in
                let array = WuiArray<CWaterUI.WuiTableColumn>(
                    waterui_read_computed_table_cols(inner))
                let views = array.toArray().map { WuiTableColumn(column: $0) }
                return views
            },
            watch: { inner, f in
                let watcher = makeTableColumnWatcher(f)
                let g = waterui_watch_computed_table_cols(inner, watcher)
                return WatcherGuard(g!)
            },
            drop: waterui_drop_computed_table_cols
        )
    }
}

extension WuiArray<CWaterUI.WuiTableColumn> {
    init(_ inner: CWaterUI.WuiArray_WuiTableColumn) {
        let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
        self.init(c: raw)
    }

}

@MainActor
private func makeTableColumnWatcher(
    _ f: @escaping ([WuiTableColumn], WuiWatcherMetadata) -> Void
) -> OpaquePointer {
    let data = wrap(f)

    let call:
        @convention(c) (UnsafeMutableRawPointer?, WuiArray_WuiTableColumn, OpaquePointer?)
            -> Void =
            {
                data, value, metadata in
                let array = WuiArray<CWaterUI.WuiTableColumn>(value)
                callWrapper(data, array.toArray().map { WuiTableColumn(column: $0) }, metadata)
            }

    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        dropWrapper($0, [WuiTableColumn].self)
    }

    guard let watcher = waterui_new_watcher_table_cols(data, call, drop) else {
        fatalError("Failed to create table column watcher")
    }
    return watcher
}
