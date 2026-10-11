/**
 * sw-register.js — Service Worker Registration & Install Prompt
 * Handles PWA lifecycle: registration, install prompts, and updates
 */

if ('serviceWorker' in navigator) {
  window.addEventListener('load', async () => {
    try {
      const reg = await navigator.serviceWorker.register('sw.js', { scope: './' });
      console.log('✓ Service Worker registered:', reg.scope);

      // Check for updates every 24 hours
      setInterval(() => {
        reg.update().catch(() => {});
      }, 24 * 60 * 60 * 1000);

      // Listen for service worker updates
      reg.addEventListener('updatefound', () => {
        const newWorker = reg.installing;
        newWorker.addEventListener('statechange', () => {
          if (newWorker.state === 'activated') {
            console.log('✓ New Service Worker activated');
          }
        });
      });
    } catch (err) {
      console.warn('✗ Service Worker registration failed:', err);
    }
  });
}

// Handle install prompt
let deferredPrompt = null;

window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  console.log('✓ Install prompt ready');
  
  // Optional: trigger install UI if you have a custom button
  const installBtn = document.getElementById('pwaInstallBtn');
  if (installBtn) {
    installBtn.hidden = false;
    installBtn.addEventListener('click', async () => {
      if (deferredPrompt) {
        deferredPrompt.prompt();
        const { outcome } = await deferredPrompt.userChoice;
        console.log(`User response: ${outcome}`);
        deferredPrompt = null;
        installBtn.hidden = true;
      }
    });
  }
});

window.addEventListener('appinstalled', () => {
  console.log('✓ PWA installed successfully');
  deferredPrompt = null;
});
