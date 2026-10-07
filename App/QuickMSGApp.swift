import SwiftUI

@main
struct QuickMSGApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 14) {
                Text("QuickMSG")
                    .font(.system(size: 34, weight: .bold))
                Text("Pré-visualização de mensagens .msg do Outlook no Finder")
                    .foregroundStyle(.secondary)
                Text("Mantém esta aplicação na pasta Aplicações. "
                     + "Seleciona um ficheiro .msg no Finder e prime a barra de espaço para o ver.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 24)
            }
            .padding(36)
            .frame(width: 480, height: 260)
        }
        .windowResizability(.contentSize)
    }
}
