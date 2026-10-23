import SwiftUI

struct BundledImage: View {
    let name: String
    var body: some View {
        if let path = Bundle.main.path(forResource: name, ofType: "jpg"), let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable()
        } else {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "photo"))
        }
    }
}
