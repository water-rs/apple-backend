// Twin of examples/reminders: a NavigationSplitView whose sidebar presents six
// smart-list destinations as a 2-column grid of colored tiles (white icon
// top-left, bold white count top-right, bold white name bottom-left), followed
// by a "My Lists" section of colored-badge rows. The detail shows a large bold
// accent-colored leading title, a divider, and "Today"/"Upcoming" reminder
// sections under small bold leading headers. Initial state: Today selected,
// empty search, all rows visible.
//
// Material icons translate to their closest SF Symbols: calendar_today →
// calendar, calendar_clock → calendar.badge.clock, inbox → tray, flag → flag,
// bell_alert → bell.badge, check → checkmark, format_list_bulleted →
// list.bullet, circle_outline → circle, plus → plus. The glyphs differ from
// the Material SVGs the example draws; what the comparison checks is the tile
// grid geometry, selection styling, and split-view chrome.

import SwiftUI

private enum Destination: Hashable, CaseIterable {
  case today, scheduled, all, flagged, urgent, completed

  var title: String {
    switch self {
    case .today: "Today"
    case .scheduled: "Scheduled"
    case .all: "All"
    case .flagged: "Flagged"
    case .urgent: "Urgent"
    case .completed: "Completed"
    }
  }

  var symbol: String {
    switch self {
    case .today: "calendar"
    case .scheduled: "calendar.badge.clock"
    case .all: "tray"
    case .flagged: "flag"
    case .urgent: "bell.badge"
    case .completed: "checkmark"
    }
  }

  var color: Color {
    switch self {
    case .today: srgbHex(0x4A84F6)
    case .scheduled: srgbHex(0xF2483F)
    case .all: srgbHex(0x54545A)
    case .flagged: srgbHex(0xF28A34)
    case .urgent: srgbHex(0xE0517E)
    case .completed: srgbHex(0x8E8E93)
    }
  }

  var selectedColor: Color {
    switch self {
    case .today: srgbHex(0x3A6FD4)
    case .scheduled: srgbHex(0xD43C34)
    case .all: srgbHex(0x44444A)
    case .flagged: srgbHex(0xD97A2B)
    case .urgent: srgbHex(0xC9446E)
    case .completed: srgbHex(0x76767B)
    }
  }

  var count: Int {
    switch self {
    case .today: 6
    case .scheduled: 2
    case .all: 18
    case .flagged: 1
    case .urgent: 0
    case .completed: 12
    }
  }
}

private struct UserList: Identifiable {
  let id: Int
  let name: String
  let count: Int
  let color: Color
}

private struct ReminderRow: Identifiable {
  let id: Int
  let title: String
  let subtitle: String?
  let flagged: Bool
}

private let userLists: [UserList] = [
  UserList(id: 1, name: "Reminders", count: 37, color: srgbHex(0xF28A34)),
  UserList(id: 2, name: "Best Shot", count: 2, color: srgbHex(0x4A84F6)),
  UserList(id: 3, name: "Road map of water", count: 12, color: srgbHex(0x4A84F6)),
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
    VStack(alignment: .leading, spacing: 6) {
      // The official app presents the smart lists as a colored tile grid.
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8
      ) {
        ForEach(Destination.allCases, id: \.self) { dest in
          tile(dest)
        }
      }
      Text("My Lists")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
      VStack(alignment: .leading, spacing: 2) {
        ForEach(userLists) { list in
          userListRow(list)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(width: 300)
    .background(.thickMaterial)
  }

  private func tile(_ dest: Destination) -> some View {
    let isSelected = selection == dest
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: dest.symbol)
          .foregroundStyle(.white)
          .frame(width: 20, height: 20)
        Spacer(minLength: 0)
        Text("\(dest.count)")
          .font(.headline)
          .bold()
          .foregroundStyle(.white)
      }
      Spacer(minLength: 0)
      Text(dest.title)
        .font(.body)
        .bold()
        .foregroundStyle(.white)
    }
    .padding(10)
    .frame(minHeight: 56)
    .background(isSelected ? dest.selectedColor : dest.color)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .onTapGesture { selection = dest }
  }

  private func userListRow(_ list: UserList) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "list.bullet")
        .foregroundStyle(.white)
        .frame(width: 14, height: 14)
        .padding(6)
        .background(list.color)
        .clipShape(Circle())
      Text(list.name).font(.body).foregroundStyle(.primary)
      Spacer(minLength: 0)
      Text("\(list.count)").font(.caption).foregroundStyle(.secondary)
    }
    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
  }

  private var detail: some View {
    NavigationStack {
      VStack(spacing: 10) {
        // The official app shows the list name as a large bold title in the
        // list's accent color, leading-aligned — no date line underneath.
        Text((selection ?? .today).title)
          .font(.system(size: 32))
          .bold()
          .foregroundStyle((selection ?? .today).color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18))
        Divider()
        reminderSection("Today", rows: todayRows)
        reminderSection("Upcoming", rows: upcomingRows)
        Spacer(minLength: 0)
      }
      .background(.regularMaterial)
      .navigationTitle((selection ?? .today).title)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
          Spacer(minLength: 0)
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
