# BLE Mesh - Complete Navigation Graph

## App Flow Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              BLE MESH APP NAVIGATION                             │
└─────────────────────────────────────────────────────────────────────────────────┘

                                    ┌─────────────┐
                                    │   App Launch │
                                    └──────┬──────┘
                                           │
                                           ▼
                              ┌────────────────────────┐
                              │    SplashScreenView    │
                              │  • Animated logo       │
                              │  • Pulse effects       │
                              │  • 2 second display    │
                              └───────────┬────────────┘
                                          │
                                          ▼
                              ┌────────────────────────┐
                              │  First Time User?      │
                              └───────────┬────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    │ NO                  │                     │ YES
                    ▼                     │                     ▼
        ┌───────────────────┐             │         ┌───────────────────┐
        │   ContentView     │             │         │  OnboardingView   │
        │   (Main App)      │             │         │   (5 Pages)       │
        └───────────────────┘             │         └─────────┬─────────┘
                                          │                   │
                                          │                   ▼
                                          │         ┌─────────────────────────────────┐
                                          │         │ Page 1: Welcome to BLE Mesh     │
                                          │         │ Page 2: Multi-Hop Routing       │
                                          │         │ Page 3: End-to-End Encrypted    │
                                          │         │ Page 4: Group Messaging         │
                                          │         │ Page 5: Ready to Connect        │
                                          │         └─────────────────┬───────────────┘
                                          │                           │
                                          │                           │ "Get Started"
                                          └───────────────────────────┘
```

---

## Main App Structure (ContentView)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                               MAIN TAB VIEW                                      │
├──────────────────────┬──────────────────────┬───────────────────────────────────┤
│       Tab 1          │       Tab 2          │           Tab 3                   │
│     "Messages"       │      "Chats"         │         "Network"                 │
└──────────┬───────────┴──────────┬───────────┴───────────────┬───────────────────┘
           │                      │                           │
           ▼                      ▼                           ▼
┌──────────────────┐   ┌──────────────────┐       ┌──────────────────────────┐
│  MessagesTab     │   │ConversationList  │       │    NetworkTabView        │
│                  │   │     View         │       │                          │
│ • Message list   │   │                  │       │ • PeersSection           │
│ • Destination    │   │ • Direct chats   │       │ • RoutingSection         │
│   picker button  │   │ • Group chats    │       │ • ControlsSection        │
│ • Input area     │   │ • Swipe actions  │       │                          │
└────────┬─────────┘   └────────┬─────────┘       └──────────────────────────┘
         │                      │
         │                      │ Tap conversation
         │                      ▼
         │             ┌──────────────────┐
         │             │   ChatView       │
         │             │                  │
         │             │ • Message bubbles│
         │             │ • Input area     │
         │             │ • Encryption     │
         │             │   toggle         │
         │             └──────────────────┘
         │
         │ Tap destination picker
         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    DESTINATION PICKER (Sheet)                         │
├──────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐   │
│  │   Broadcast     │  │  Direct Peers   │  │      Groups         │   │
│  │   (Everyone)    │  │  (Discovered)   │  │   (Your groups)     │   │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘   │
│                                                        │              │
│                                         ┌──────────────┘              │
│                                         ▼                             │
│                              ┌─────────────────────┐                  │
│                              │  Create New Group   │                  │
│                              │      Button         │                  │
│                              └──────────┬──────────┘                  │
│                                         │                             │
│                                         ▼                             │
│                              ┌─────────────────────┐                  │
│                              │   NewGroupView      │                  │
│                              │   (Sheet)           │                  │
│                              └─────────────────────┘                  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Settings Navigation (from Toolbar Gear Icon)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           SETTINGS VIEW (Sheet)                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Device                                                           │   │
│  │  • Name (read-only)                                                       │   │
│  │  • ID (read-only)                                                         │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Security                                                         │   │
│  │  • Encrypt Messages by Default (Toggle)                                   │   │
│  │  • Encryption Details ──────────────────────────► EncryptionDetailsView   │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Network                                                          │   │
│  │  • Auto Reconnect (Toggle)                                                │   │
│  │  • Connected Peers (read-only)                                            │   │
│  │  • Known Routes (read-only)                                               │   │
│  │  • Network Diagnostics ─────────────────────────► NetworkDiagnosticsView  │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Messages                                                         │   │
│  │  • Show Delivery Status (Toggle)                                          │   │
│  │  • Message Retention (Picker)                                             │   │
│  │  • Stored Messages (read-only)                                            │   │
│  │  • Clear Message History (Destructive Button)                             │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Notifications                                                    │   │
│  │  • Enable Notifications (Toggle)                                          │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Statistics                                                       │   │
│  │  • Messages Sent                                                          │   │
│  │  • Messages Received                                                      │   │
│  │  • Encrypted Messages                                                     │   │
│  │  • Messages Relayed                                                       │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: About                                                            │   │
│  │  • Version                                                                │   │
│  │  • About BLE Mesh ──────────────────────────────► AboutView               │   │
│  │  • View Onboarding ─────────────────────────────► OnboardingReplayView    │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │ Section: Debug                                                            │   │
│  │  • Reset All Settings (Destructive)                                       │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Group Management Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          GROUP MANAGEMENT FLOW                                   │
└─────────────────────────────────────────────────────────────────────────────────┘

                    From ConversationListView
                              │
                              │ Swipe or tap info button on group
                              ▼
                    ┌─────────────────────┐
                    │  GroupSettingsView  │
                    │      (Sheet)        │
                    └─────────┬───────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐   ┌─────────────────┐   ┌─────────────────┐
│ Group Info    │   │ Member List     │   │ Actions         │
│ • Name        │   │ • View members  │   │ • Leave Group   │
│ • Created     │   │ • Add member    │   │ • Delete Group  │
│ • Member count│   │ • Remove member │   │                 │
└───────────────┘   └─────────────────┘   └─────────────────┘


                    Creating New Group
                              │
                              │ From Destination Picker
                              ▼
                    ┌─────────────────────┐
                    │   NewGroupView      │
                    │      (Sheet)        │
                    └─────────┬───────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐   ┌─────────────────┐   ┌─────────────────┐
│ Group Name    │   │ Select Members  │   │ Create Button   │
│ Text Input    │   │ From peer list  │   │ Creates group   │
└───────────────┘   └─────────────────┘   └─────────────────┘
```

---

## Complete View Hierarchy

```
BLEMeshApp
    └── RootView
            ├── SplashScreenView (initial, 2 seconds)
            │
            ├── OnboardingView (if first time)
            │       └── OnboardingPageView (×5 pages)
            │
            └── ContentView (main app)
                    │
                    ├── [Tab 1] MessagesTab
                    │       ├── MessageBubble (×n messages)
                    │       ├── MessageInputView
                    │       └── DestinationPickerView (sheet)
                    │               ├── DirectMessageRow (×n peers)
                    │               ├── GroupRow (×n groups)
                    │               └── NewGroupView (sheet)
                    │
                    ├── [Tab 2] ConversationListView
                    │       ├── ConversationRow (×n conversations)
                    │       │       └── GroupSettingsView (sheet/swipe)
                    │       └── ChatView (push navigation)
                    │               └── ChatMessageBubble (×n messages)
                    │
                    ├── [Tab 3] NetworkTabView
                    │       ├── PeersSection
                    │       │       └── PeerRow (×n peers)
                    │       ├── RoutingSection
                    │       └── ControlsSection
                    │
                    └── [Toolbar] SettingsView (sheet)
                            ├── EncryptionDetailsView (push)
                            ├── NetworkDiagnosticsView (push)
                            ├── AboutView (push)
                            └── OnboardingReplayView (sheet)
```

---

## Screen Count Summary

| Category | Screens | Description |
|----------|---------|-------------|
| **Launch** | 1 | SplashScreenView |
| **Onboarding** | 2 | OnboardingView, OnboardingReplayView |
| **Main Tabs** | 3 | MessagesTab, ConversationListView, NetworkTabView |
| **Chat** | 2 | ChatView, ChatMessageBubble |
| **Pickers** | 2 | DestinationPickerView, DestinationPickerSheet |
| **Groups** | 3 | NewGroupView, GroupSettingsView, GroupRow |
| **Settings** | 4 | SettingsView, EncryptionDetailsView, NetworkDiagnosticsView, AboutView |
| **Components** | 5 | MessageBubble, PeerRow, ConversationRow, MessageInputView, DirectMessageRow |
| **Total** | **22** | Unique view structs |

---

## Navigation Methods Used

| Method | Usage |
|--------|-------|
| `TabView` | Main app navigation (3 tabs) |
| `.sheet()` | Settings, DestinationPicker, NewGroup, GroupSettings, OnboardingReplay |
| `NavigationLink` | EncryptionDetails, NetworkDiagnostics, About, ChatView |
| `.swipeActions()` | ConversationRow (group settings, leave) |
| Conditional | RootView (splash → onboarding → main) |
| `@AppStorage` | Onboarding completion persistence |

---

## User Journey

### First-Time User
```
Launch → Splash (2s) → Onboarding (5 pages) → Main App
```

### Returning User
```
Launch → Splash (2s) → Main App
```

### Sending a Message
```
Messages Tab → Tap destination picker → Select peer/group → Type message → Send
```

### Creating a Group
```
Messages Tab → Destination picker → "Create New Group" → Name group → Select members → Create
```

### Viewing Group Settings
```
Chats Tab → Swipe on group OR tap info → GroupSettingsView
```

### Accessing Settings
```
Any Tab → Tap gear icon (toolbar) → SettingsView
```
