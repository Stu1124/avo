// deps: Avo/Tools/DDGParser.swift
import Foundation

// The parse behind web_search. DuckDuckGo's HTML endpoint hides every result behind its own
// redirector, so the url that matters is the escaped `uddg=` parameter, not the href. Titles and
// snippets arrive with entities and with the search terms wrapped in <b>. Sponsored rows carry the
// same class as a real result and must not come back as one.

@main
struct WebToolsTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if !ok { failures += 1; print("  x \(label)") }
    }

    static func checkEqual(_ label: String, _ got: String, _ want: String) {
        guard got != want else { return }
        failures += 1
        print("  x \(label)\n    got:  \"\(got)\"\n    want: \"\(want)\"")
    }

    /// Two results as the endpoint really writes them: an ad first, then a redirected link with
    /// entities in the title, then one whose snippet lives in a div rather than an anchor.
    static let fixture = """
    <!DOCTYPE html>
    <html><head><title>apple news at DuckDuckGo</title></head><body>
    <div class="results">
      <div class="result results_links result--ad">
        <div class="links_main">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/y.js?ad_domain=example.com&amp;ad_provider=bingv7">Sponsored thing</a>
          </h2>
          <a class="result__snippet">Buy the sponsored thing.</a>
        </div>
      </div>
      <div class="result results_links results_links_deep web-result">
        <div class="links_main links_deep result__body">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.apple.com%2Fnewsroom%2F&amp;rut=9f1c">Apple Newsroom &amp; Press Releases</a>
          </h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.apple.com%2Fnewsroom%2F">The <b>latest</b> news &amp; updates &mdash; read Apple&#39;s announcements.</a>
        </div>
      </div>
      <div class="result results_links results_links_deep web-result">
        <div class="links_main links_deep result__body">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.reuters.com%2Ftechnology%2Fapple%2F&amp;rut=22b0">Apple | Reuters</a>
          </h2>
          <div class="result__snippet">Breaking&nbsp;news about Apple, from&#x20;Reuters.</div>
        </div>
      </div>
    </div>
    </body></html>
    """

    static func main() {
        let results = DDGParser.results(from: fixture, limit: 5)

        check("two results, ad dropped", results.count == 2)
        guard results.count == 2 else {
            print("FAIL: WebToolsTests (parsed \(results.count) results)")
            exit(1)
        }

        // The redirect is decoded back to the real destination, entities and all.
        checkEqual("first url", results[0].url, "https://www.apple.com/newsroom/")
        checkEqual("first title", results[0].title, "Apple Newsroom & Press Releases")
        checkEqual("first snippet", results[0].snippet, "The latest news & updates — read Apple's announcements.")

        checkEqual("second url", results[1].url, "https://www.reuters.com/technology/apple/")
        checkEqual("second title", results[1].title, "Apple | Reuters")
        // &nbsp; and a numeric hex entity both collapse into ordinary single spaces.
        checkEqual("second snippet (div)", results[1].snippet, "Breaking news about Apple, from Reuters.")

        // max_results is a ceiling the parse honours.
        check("limit honoured", DDGParser.results(from: fixture, limit: 1).count == 1)
        check("zero limit", DDGParser.results(from: fixture, limit: 0).isEmpty)

        // Nothing to parse is not a crash and not a fabricated result.
        check("empty page", DDGParser.results(from: "", limit: 5).isEmpty)
        check("page with no results", DDGParser.results(from: "<html><body><p>No results.</p></body></html>", limit: 5).isEmpty)
        check("blocked page", DDGParser.results(from: "<html><body>anomaly detected</body></html>", limit: 5).isEmpty)

        // Entity decoding on its own, including what must be left alone.
        checkEqual("named entities", DDGParser.decodeEntities("a &amp; b &lt;c&gt; &quot;d&quot;"), "a & b <c> \"d\"")
        checkEqual("numeric entities", DDGParser.decodeEntities("&#39;&#x2014;"), "'—")
        checkEqual("unknown entity kept", DDGParser.decodeEntities("&notanentity;"), "&notanentity;")
        checkEqual("bare ampersand kept", DDGParser.decodeEntities("a & b"), "a & b")

        // read_page's side: scripts and styles go, block ends stay as line breaks.
        let page = """
        <html><head><title>  Hello &amp; welcome </title>
        <style>body{color:red}</style></head>
        <body><script>var x = "<p>not text</p>";</script>
        <h1>Heading</h1><p>First   paragraph.</p><p>Second one.</p>
        <!-- a comment --></body></html>
        """
        checkEqual("page title", DDGParser.title(fromHTML: page), "Hello & welcome")
        checkEqual("page text", DDGParser.readableText(fromHTML: page, limit: 6000),
                   "Heading\nFirst paragraph.\nSecond one.")
        checkEqual("page text truncated", DDGParser.readableText(fromHTML: page, limit: 7), "Heading")

        if failures == 0 {
            print("PASS: DuckDuckGo result parsing, redirect decoding, entities, page text")
        } else {
            print("FAIL: WebToolsTests (\(failures))")
            exit(1)
        }
    }
}
