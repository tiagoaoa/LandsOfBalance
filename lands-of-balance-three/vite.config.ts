import { defineConfig } from 'vite'

export default defineConfig({
  server: { host: '127.0.0.1', port: 5273 },
  build: { target: 'es2022', chunkSizeWarningLimit: 4000 },
  resolve: {
    alias: [
      // Everything must resolve to the SAME three build. The node/WebGPU
      // build is a superset of the classic one, so aliasing bare `three` onto
      // it means the addons (GLTFLoader, SkeletonUtils, OBJLoader) and
      // three-mesh-bvh all share one copy — two copies of three in a bundle
      // means two class registries and silent `instanceof` failures.
      { find: /^three$/, replacement: 'three/webgpu' },
    ],
  },
})
