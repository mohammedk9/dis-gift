/*
 * Public runtime configuration.
 *
 * GitHub Pages cannot read .env files in the browser. The Pages workflow
 * replaces this file with values from GitHub Secrets during deployment.
 * The anon/publishable key is safe to ship to the browser; never put a
 * service_role key in this file.
 */
window.__HADIYA_CONFIG__ = Object.freeze({
  supabaseUrl: '',
  supabaseAnonKey: '',
  configSource: 'source-placeholder'
});