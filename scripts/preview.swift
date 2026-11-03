import Foundation
// Asks a running Mac Duo to play its preview sweep.
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.abukotsh.MacDuo.preview"), object: nil, userInfo: nil, deliverImmediately: true
)
