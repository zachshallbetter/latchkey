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
