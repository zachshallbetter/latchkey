import Foundation

/// The service that issued a value (Stripe, Neon, GitHub…), guessed on import from the value's shape and the
/// key's name. A guess only fills an empty field; it never overrides what someone set.
public enum Services {
    /// Distinctive token prefixes. Checked first: they identify the issuer even under a generic key name.
    static let valuePrefixes: [(String, String)] = [
        ("sk_live_", "Stripe"), ("sk_test_", "Stripe"), ("pk_live_", "Stripe"), ("pk_test_", "Stripe"),
        ("rk_live_", "Stripe"), ("rk_test_", "Stripe"), ("whsec_", "Stripe"),
        ("github_pat_", "GitHub"), ("ghp_", "GitHub"), ("gho_", "GitHub"), ("ghs_", "GitHub"), ("ghu_", "GitHub"),
        ("glpat-", "GitLab"), ("xoxb-", "Slack"), ("xoxp-", "Slack"), ("xapp-", "Slack"),
        ("sk-ant-", "Anthropic"), ("sk-proj-", "OpenAI"), ("AKIA", "AWS"), ("ASIA", "AWS"), ("AIza", "Google"),
        ("SG.", "SendGrid"), ("re_", "Resend"), ("npm_", "npm"), ("dop_v1_", "DigitalOcean"),
        ("phc_", "PostHog"), ("phx_", "PostHog"), ("sk_clerk_", "Clerk"), ("lin_api_", "Linear"),
    ]

    /// Hosts inside connection strings and URLs.
    static let hosts: [(String, String)] = [
        ("neon.tech", "Neon"), ("supabase.co", "Supabase"), ("supabase.com", "Supabase"), ("upstash.io", "Upstash"),
        ("psdb.cloud", "PlanetScale"), ("rlwy.net", "Railway"), ("railway.app", "Railway"), ("render.com", "Render"),
        ("mongodb.net", "MongoDB Atlas"), ("amazonaws.com", "AWS"), ("azure.com", "Azure"), ("windows.net", "Azure"),
        ("googleapis.com", "Google"), ("cloudflare.com", "Cloudflare"), ("vercel.com", "Vercel"),
        ("sentry.io", "Sentry"), ("fly.dev", "Fly"), ("fly.io", "Fly"), ("redis-cloud.com", "Redis Cloud"),
        ("turso.io", "Turso"), ("convex.cloud", "Convex"), ("pusher.com", "Pusher"), ("algolia.net", "Algolia"),
    ]

    /// Key-name prefixes, last resort.
    static let keyPrefixes: [(String, String)] = [
        ("STRIPE_", "Stripe"), ("GITHUB_", "GitHub"), ("GH_", "GitHub"), ("VERCEL_", "Vercel"), ("OPENAI_", "OpenAI"),
        ("ANTHROPIC_", "Anthropic"), ("GEMINI_", "Google"), ("GOOGLE_", "Google"), ("GCP_", "Google"),
        ("FIREBASE_", "Firebase"), ("SENTRY_", "Sentry"), ("CLERK_", "Clerk"), ("RESEND_", "Resend"), ("NEON_", "Neon"),
        ("SUPABASE_", "Supabase"), ("AWS_", "AWS"), ("CLOUDFLARE_", "Cloudflare"), ("CF_", "Cloudflare"),
        ("TWILIO_", "Twilio"), ("SLACK_", "Slack"), ("POSTHOG_", "PostHog"), ("UPSTASH_", "Upstash"),
        ("LINEAR_", "Linear"), ("NOTION_", "Notion"), ("SENDGRID_", "SendGrid"), ("MAILGUN_", "Mailgun"),
        ("ALGOLIA_", "Algolia"), ("FLY_", "Fly"), ("RAILWAY_", "Railway"), ("APPLE_", "Apple"), ("ASC_", "Apple"),
    ]

    /// Where to make a new key, for services whose page is stable. Rotation sends you here; none of these services
    /// lets Latchkey roll a key for you through an API.
    public static let keyPages: [String: String] = [
        "Stripe": "https://dashboard.stripe.com/apikeys",
        "GitHub": "https://github.com/settings/tokens",
        "OpenAI": "https://platform.openai.com/api-keys",
        "Anthropic": "https://console.anthropic.com/settings/keys",
        "Vercel": "https://vercel.com/account/tokens",
        "Resend": "https://resend.com/api-keys",
        "Neon": "https://console.neon.tech",
        "Railway": "https://railway.com/account/tokens",
        "Sentry": "https://sentry.io/settings/account/api/auth-tokens/",
        "Cloudflare": "https://dash.cloudflare.com/profile/api-tokens",
        "Google": "https://console.cloud.google.com/apis/credentials",
        "AWS": "https://console.aws.amazon.com/iam/home#/security_credentials",
        "Supabase": "https://supabase.com/dashboard",
        "Clerk": "https://dashboard.clerk.com",
        "Slack": "https://api.slack.com/apps",
        "Fly": "https://fly.io/dashboard",
    ]

    /// Sites Latchkey for Safari may fill any item on: where keys are set as a deployment's environment variables or
    /// secrets. An item may also be filled on its own service's site (see `keyPages`). Matched by host and its
    /// subdomains, https only, so every entry is a domain whose subdomains only the platform serves: never one where
    /// customers get their own subdomains (railway.app, vercel.app, netlify.app, onrender.com, fly.dev, herokuapp.com).
    public static let fillPlatforms = [
        "vercel.com", "github.com", "railway.com", "fly.io", "app.netlify.com", "dashboard.render.com",
        "dash.cloudflare.com", "supabase.com", "dashboard.heroku.com", "console.aws.amazon.com", "console.cloud.google.com",
    ]

    /// The host of an https page origin, or nil for anything else (http, a file, a port, a malformed origin).
    public static func fillHost(_ origin: String) -> String? {
        guard let url = URL(string: origin), url.scheme == "https", url.port == nil, url.user == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Whether Latchkey for Safari may fill this item into a page at `origin`. An item with its own fill sites goes
    /// only to those (each covering its subdomains); otherwise to a deployment platform or its service's own site.
    public static func mayFill(origin: String, item: SecretInfo) -> Bool {
        guard let sites = item.fillSites, !sites.isEmpty else { return mayFill(origin: origin, service: item.service) }
        guard let host = fillHost(origin) else { return false }
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The default: a deployment platform, or the service's own key page host and its subdomains (such as
    /// dashboard.stripe.com), not the whole registrable domain, which can include sites the service hosts for others.
    public static func mayFill(origin: String, service: String?) -> Bool {
        guard let host = fillHost(origin) else { return false }
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if fillPlatforms.contains(where: under) { return true }
        guard let service, let page = keyPages[service], let pageHost = URL(string: page)?.host?.lowercased() else { return false }
        return under(pageHost)
    }

    public struct FillSiteError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Fill sites as typed ("vercel.com", "https://app.netlify.com/teams"), as host names: lowercased, without scheme,
    /// port or path, no repeats, sorted. At most 20. An empty list is valid: it means the default.
    public static func fillSites(_ given: [String]) -> Result<[String], FillSiteError> {
        var hosts: [String] = []
        for raw in given {
            var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if s.isEmpty { continue }
            if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
            s = String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            if s.hasPrefix("*.") { s.removeFirst(2) }
            let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
            guard s.range(of: "^\(label)(\\.\(label))+$", options: .regularExpression) != nil, !s.contains("@"), !s.contains(":") else {
                return .failure(FillSiteError(description: "\(raw) isn't a site; give a host name such as vercel.com"))
            }
            if !hosts.contains(s) { hosts.append(s) }
        }
        guard hosts.count <= 20 else { return .failure(FillSiteError(description: "at most 20 fill sites per item")) }
        return .success(hosts.sorted())
    }

    public static func guess(key: String, value: String) -> String? {
        for (prefix, service) in valuePrefixes where value.hasPrefix(prefix) { return service }
        let lower = value.lowercased()
        if lower.contains("://") || lower.contains("@") {
            for (host, service) in hosts where lower.contains(host) { return service }
        }
        let k = key.uppercased()
        for (prefix, service) in keyPrefixes where k.hasPrefix(prefix) { return service }
        return nil
    }
}
