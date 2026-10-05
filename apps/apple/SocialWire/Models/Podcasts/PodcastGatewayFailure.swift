import Foundation

struct PodcastGatewayFailure: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401, 403: "Sign In Again to Use Podcasts"
        case 409: "Podcast State Changed on Another Device. Refresh and Try Again."
        case 404: "Podcasts Are Not Available in This Environment"
        default: "Podcast Request Failed (\(status)). Try Again."
        }
    }
}
