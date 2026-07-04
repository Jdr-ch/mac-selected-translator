"""CLI entrypoint for the local translator backend."""

from .server import main


if __name__ == "__main__":
    raise SystemExit(main())
