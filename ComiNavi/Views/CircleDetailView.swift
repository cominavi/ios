//
//  CircleDetailView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/17/24.
//

import SwiftUI
import WebKit

// <a class="twitter-timeline" data-lang="ja" data-dnt="true" data-theme="dark" href="https://twitter.com/asagi_0398?ref_src=twsrc%5Etfw">Tweets by asagi_0398</a> <script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>

class CircleTwitterEmbedWebView: UIViewController, WKUIDelegate {
    var webView: WKWebView!
    var twitterUsername: String

    init(twitterUsername: String) {
        self.twitterUsername = twitterUsername
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let webConfiguration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.uiDelegate = self
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.configuration.preferences.minimumFontSize = 8.0
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // create html
        // 168px: 400px frame height / 2 - 48px preloader height / 2
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Twitter Timeline</title>
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    color-scheme: light dark;
                }
                html, body, .twitter-timeline {
                    width: 100%;
                    height: 100%;
                }
                a.twitter-timeline {
                    color: inherit;
                    text-decoration: none;
                }
            </style>
        </head>
        <body>
            <a class="twitter-timeline" data-chrome="noheader nofooter noborders" data-lang="ja" data-dnt="true" data-theme="\(self.traitCollection.userInterfaceStyle == .dark ? "dark" : "light")" href="https://twitter.com/\(twitterUsername)">
                <svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24" style="margin: 0 auto; display: block; padding: 1em; fill: currentColor; position: fixed; top: 168px; left: 50%; transform: translateX(-50%); width: 32px; height: 32px; opacity: 0.5">
                    <path fill="currentColor" d="M12,4a8,8,0,0,1,7.89,6.7A1.53,1.53,0,0,0,21.38,12h0a1.5,1.5,0,0,0,1.48-1.75,11,11,0,0,0-21.72,0A1.5,1.5,0,0,0,2.62,12h0a1.53,1.53,0,0,0,1.49-1.3A8,8,0,0,1,12,4Z">
                        <animateTransform attributeName="transform" dur="2.25s" repeatCount="indefinite" type="rotate" values="0 12 12;360 12 12" />
                    </path>
                </svg>
            </a>
            <script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // open links in Safari
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

struct CircleTwitterEmbedWebViewRepresentable: UIViewControllerRepresentable {
    var twitterUsername: String

    func makeUIViewController(context: Context) -> CircleTwitterEmbedWebView {
        return CircleTwitterEmbedWebView(twitterUsername: twitterUsername)
    }

    func updateUIViewController(_ uiViewController: CircleTwitterEmbedWebView, context: Context) {}
}

struct CircleDetailView: View {
    var circle: CirclemsDataSchema.ComiketCircleWC

    @State var circleExtend: CirclemsDataSchema.ComiketCircleExtend?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                CirclePreviewView(circle: circle)

                Text("Twitter Timeline")
                    .font(.title)
                    .bold()
                    .padding(.top)

                if let twitterUsername = circleExtend?.twitterURL?.lastPathComponent, !twitterUsername.isEmpty {
                    CircleTwitterEmbedWebViewRepresentable(twitterUsername: twitterUsername)
                        .frame(height: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray, lineWidth: 1))
                } else {
                    Text("No Twitter timeline found.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .flexibleFrame(.horizontal, alignment: .topLeading)
        }
        .apply {
            if #available(iOS 16.0, *) {
                $0.scrollIndicators(.automatic)
            }
        }
    }
}

#Preview {
    CircleDetailView(circle: AppData.circlems.getDemoCircles().first!)
}
