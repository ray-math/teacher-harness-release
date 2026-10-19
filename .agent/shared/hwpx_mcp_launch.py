"""Start the verified MCP with current configured roots, keeping stdio untouched."""
import os
import runpy
import sys

from hwpx_read_client import server_parameters


def main():
    parameters = server_parameters()
    os.environ.update(parameters.env or {})
    sys.argv = ['hwpx-automation-mcp', *parameters.args[3:]]
    runpy.run_module('hwpx_automation.mcp_cli', run_name='__main__')


if __name__ == '__main__':
    main()
