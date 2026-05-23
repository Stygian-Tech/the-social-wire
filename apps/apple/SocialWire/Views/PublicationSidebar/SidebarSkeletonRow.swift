import SwiftUI

struct SidebarSkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 28, height: 28)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.14))
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .redacted(reason: .placeholder)
        .readerClearListRow()
    }
}
