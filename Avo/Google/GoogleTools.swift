import Foundation

/// All Google-backed tools (Gmail, Google Calendar, Google Drive). Registered by AvoApp.
enum GoogleTools {
    static func all() -> [Tool] {
        gmail() + calendar() + drive()
    }
    static func gmail() -> [Tool] {
        [GmailListUnread(), GmailSearch(), GmailReadMessage(), GmailSend(), GmailReply(), GmailArchive(), GmailMarkRead()]
    }
    static func calendar() -> [Tool] {
        [GCalListCalendars(), GCalListEvents(), GCalSearchEvents(), GCalFindFreeSlots(), GCalCreateEvent(), GCalUpdateEvent(), GCalDeleteEvent()]
    }
    static func drive() -> [Tool] {
        [DriveSearch(), DriveRecentFiles(), DriveReadFile(), DriveOpen(), DriveCreateDoc()]
    }
}
