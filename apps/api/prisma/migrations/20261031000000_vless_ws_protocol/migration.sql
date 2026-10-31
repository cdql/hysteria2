-- Add VLESS_WS (Cloudflare Tunnel + VLESS WS) to the node protocol enum.
ALTER TYPE "NodeProtocol" ADD VALUE 'VLESS_WS';

-- Optional WebSocket path for VLESS_WS nodes (node-level, shared by all users).
ALTER TABLE "Node" ADD COLUMN "wsPath" TEXT;
