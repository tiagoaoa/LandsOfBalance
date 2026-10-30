"""Run a file through the project's Blender MCP server."""
import asyncio
import os
import sys
from datetime import timedelta
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    env = dict(os.environ)
    env['BLENDER_HOST'] = '127.0.0.1'
    env['BLENDER_PORT'] = '9876'
    env['BLENDER_MCP_DISABLE_TELEMETRY'] = '1'
    server = StdioServerParameters(command=sys.executable,
                                  args=['-m', 'blender_mcp.server'], env=env)
    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write,
                                 read_timeout_seconds=timedelta(minutes=15)) as session:
            await session.initialize()
            tool = sys.argv[1] if len(sys.argv) > 1 else 'get_scene_info'
            args = {'user_prompt': 'Use Blender MCP to improve the colossus boss and level: modelling, textures, lighting and combat animations. Serious, dark, noir, adult. The boss must be a giant anthropomorphic lizard man, not a dragon.'}
            if tool == 'execute_blender_code':
                path = str(Path(sys.argv[2]).resolve())
                args['code'] = "exec(compile(open(%r).read(), %r, 'exec'), {'__file__': %r, '__name__': '__main__'})" % (path, path, path)
            result = await session.call_tool(tool, args)
            for part in result.content:
                if hasattr(part, 'text'):
                    print(part.text)
            if result.isError or any(getattr(p, 'text', '').startswith('Error') for p in result.content):
                raise SystemExit(1)


asyncio.run(main())
