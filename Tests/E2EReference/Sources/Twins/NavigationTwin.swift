// Twin of examples/navigation: four toolbar tabs, the Inbox pane on screen —
// a NavigationStack with a large title, an unread-count subtitle, a search
// field, an Edit leading item, a Compose primary action, a Mark All Read
// bottom-bar item and a status item, over a list of message rows. Only the
// settled first screen is rendered, so routes and actions are inert.
//
// Material icons translate to their closest SF Symbols: inbox → tray,
// image_album → photo.on.rectangle, view_gallery → square.grid.2x2,
// cog → gearshape, pencil → square.and.pencil, flag → flag.

import SwiftUI

private struct Message: Identifiable {
  let id: Int
  let sender: String
  let subject: String
  let preview: String
  var unread: Bool
  var flagged: Bool
}

private let seedMessages: [Message] = [
  ("Ada Lovelace", "Analytical engine notes", "The engine weaves algebraic patterns."),
  ("Grace Hopper", "Compiler timings", "Shaved another pass off the linker."),
  ("Alan Kay", "On messaging", "The big idea is messaging, not objects."),
  ("Barbara Liskov", "Substitution review", "Subtypes must not surprise their callers."),
  ("Ken Thompson", "Pipes", "One tool, one job, composed by the shell."),
  ("Margaret Hamilton", "Priority displays", "Overload handling saved the landing."),
].enumerated().map { index, fields in
  Message(
    id: index,
    sender: fields.0,
    subject: fields.1,
    preview: fields.2,
    unread: index % 2 == 0,
    flagged: false
  )
}

private enum Pane: Hashable {
  case inbox, library, gallery, settings
}

struct NavigationTwin: View {
  @State private var pane = Pane.inbox
  @State private var query = ""
  @State private var editing = false

  private var unreadCount: Int {
    seedMessages.filter(\.unread).count
  }

  var body: some View {
    TabView(selection: $pane) {
      Tab("Inbox", systemImage: "tray", value: .inbox) {
        inboxPane
      }
      .badge(unreadCount)
      Tab("Library", systemImage: "photo.on.rectangle", value: .library) {
        librarySplit
      }
      Tab("Gallery", systemImage: "square.grid.2x2", value: .gallery) {
        Text("Gallery")
      }
      Tab("Settings", systemImage: "gearshape", value: .settings) {
        Text("Settings")
      }
    }
  }

  private enum Album: String, Hashable {
    case recents = "Recents"
    case favorites = "Favorites"
    case shared = "Shared with You"
    var count: Int {
      switch self {
      case .recents: return 128
      case .favorites: return 12
      case .shared: return 41
      }
    }
  }

  @State private var album: Album? = .recents

  private var librarySplit: some View {
    NavigationSplitView {
      List(selection: $album) {
        Section("Albums") {
          ForEach([Album.recents, .favorites, .shared], id: \.self) { album in
            Label {
              HStack {
                Text(album.rawValue)
                Spacer(minLength: 0)
                Text("\(album.count)").foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "photo.on.rectangle")
            }
            .tag(album)
          }
        }
      }
      .navigationTitle("Albums")
      .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    } detail: {
      VStack(alignment: .leading, spacing: 6) {
        Text("128 photos")
        Text(
          "On a wide window this is the trailing column beside the sidebar; on a phone the same declaration collapses into a pushed page with a back button."
        )
        .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var inboxPane: some View {
    NavigationStack {
      List(seedMessages) { message in
        NavigationLink(value: message.id) {
          HStack(alignment: .top, spacing: 6) {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 8, height: 8)
              .opacity(message.unread ? 1 : 0)
              .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(message.sender).font(.subheadline)
                Spacer(minLength: 0)
                if message.flagged {
                  Image(systemName: "flag")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                }
              }
              Text(message.subject).font(.body)
              Text(message.preview).font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 8)
        }
      }
      .navigationTitle("Inbox")
      .navigationSubtitle("\(unreadCount) unread")
      .searchable(text: $query, prompt: "Search mail")
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button(editing ? "Done" : "Edit") {}
            .buttonStyle(.plain)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {} label: {
            Label("Compose", systemImage: "square.and.pencil")
          }
        }
        // The bottom toolbar is an iOS construct; on the Mac the example's
        // bottom-bar item has no slot to land in and is not shown.
        #if os(iOS)
          ToolbarItem(placement: .bottomBar) {
            Button("Mark All Read") {}
              .buttonStyle(.plain)
          }
        #endif
        ToolbarItem(placement: .status) {
          Text("\(unreadCount) unread")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationDestination(for: Int.self) { _ in
        Text("Message")
      }
    }
  }
}
