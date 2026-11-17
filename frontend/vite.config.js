import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    proxy: {
      '/api': {
        target: process.env.BFF_URL || 'http://localhost:3000',
        changeOrigin: true,
        configure(proxy) {
          proxy.on('proxyReq', (proxyReq) => proxyReq.setHeader('origin', process.env.BFF_ORIGIN || 'http://localhost:3000'));
        },
      },
    },
  },
  build: { outDir: 'dist', emptyOutDir: true },
});
