// Twin of examples/reminders: a NavigationSplitView whose sidebar lists five
// destinations as icon + title + count rows, detail showing Today's "Today"
// and "Upcoming" reminder sections under a large header. Initial state:
// Today selected, empty search, all rows visible.
//
// Material icons translate to their closest SF Symbols: calendar_today →
// calendar, calendar_clock → calendar.badge.clock, inbox → tray, flag → flag,
// check_circle → checkmark.circle, circle_outline → circle, plus → plus. The
// glyphs differ from the Material SVGs the example draws; what the comparison
// checks is the row layout, selection styling, and split-view chrome.

import SwiftUI

private enum Destination: Hashable {
  case today, scheduled, all, flagged, completed

  var title: String {
    switch self {
    case .today: "Today"
    case .scheduled: "Scheduled"
    case .all: "All"
    case .flagged: "Flagged"
    case .completed: "Completed"
    }
  }

  var symbol: String {
    switch self {
    case .today: "calendar"
    case .scheduled: "calendar.badge.clock"
    case .all: "tray"
    case .flagged: "flag"
    case .completed: "checkmark.circle"
    }
  }

  var tint: Color {
    switch self {
    case .today: srgbHex(0x4A84F6)
    case .scheduled: srgbHex(0xF5B84A)
    case .all: srgbHex(0x8F8F96)
    case .flagged: srgbHex(0xF28A34)
    case .completed: srgbHex(0x30BA61)
    }
  }
}

private struct SidebarRow: Identifiable {
  let id: Int
  let dest: Destination
  let count: Int
}

private struct ReminderRow: Identifiable {
  let id: Int
  let title: String
  let subtitle: String?
  let flagged: Bool
}

private let sidebarRows: [SidebarRow] = [
  SidebarRow(id: 1, dest: .today, count: 6),
  SidebarRow(id: 2, dest: .scheduled, count: 2),
  SidebarRow(id: 3, dest: .all, count: 18),
  SidebarRow(id: 4, dest: .flagged, count: 1),
  SidebarRow(id: 5, dest: .completed, count: 12),
]

private let todayRows: [ReminderRow] = [
  ReminderRow(id: 1, title: "Call dentist", subtitle: "2:00 PM", flagged: false),
  ReminderRow(
    id: 2, title: "Review navigation parity worktree", subtitle: "Before lunch", flagged: true),
]

private let upcomingRows: [ReminderRow] = [
  ReminderRow(id: 3, title: "Pick up package", subtitle: "Tomorrow 10:00 AM", flagged: false)
]

struct RemindersTwin: View {
  @State private var selection: Destination? = .today
  @State private var search = ""

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    } detail: {
      detail
    }
  }

  private var sidebar: some View {
    VStack(spacing: 10) {
      VStack(spacing: 10) {
        Text("Reminders").font(.title).bold().foregroundStyle(.primary)
        Text("Search: \(search)").font(.caption).foregroundStyle(.secondary)
        Text("My Lists").font(.caption).foregroundStyle(.secondary)
      }
      .padding(16)
      List(sidebarRows) { row in
        HStack(spacing: 10) {
          Image(systemName: row.dest.symbol)
            .foregroundStyle(row.dest.tint)
            .frame(width: 18, height: 18)
          Text(row.dest.title).font(.body).foregroundStyle(.primary)
          Spacer()
          Text("\(row.count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(selection == row.dest ? Color.white.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { selection = row.dest }
      }
    }
    .frame(width: 300)
    .background(.thickMaterial)
  }

  private var detail: some View {
    NavigationStack {
      VStack(spacing: 10) {
        VStack(spacing: 6) {
          Text("Today").font(.title).bold().foregroundStyle(.primary)
          Text("Friday, February 6").font(.caption).foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18))
        Divider()
        reminderSection("Today", rows: todayRows)
        reminderSection("Upcoming", rows: upcomingRows)
      }
      .background(.regularMaterial)
      .navigationTitle("Today")
      .searchable(text: $search, prompt: "Search reminders")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {} label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }

  private func reminderSection(_ title: String, rows: [ReminderRow]) -> some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.caption)
        .bold()
        .foregroundStyle(.secondary)
        .padding(EdgeInsets(top: 8, leading: 18, bottom: 0, trailing: 18))
      List(rows) { row in
        HStack(spacing: 10) {
          Image(systemName: "circle")
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(row.title).font(.body).foregroundStyle(.primary)
            if let subtitle = row.subtitle {
              Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if row.flagged {
            Image(systemName: "flag")
              .foregroundStyle(srgbHex(0xF28A34))
              .frame(width: 12, height: 12)
          } else {
            Spacer().frame(width: 12)
          }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
      }
    }
  }
}
