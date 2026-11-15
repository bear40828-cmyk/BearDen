"""Exercise the album service using isolated temporary storage, never production data."""
from pathlib import Path
import subprocess


def test_shared_albums():
    root = Path(__file__).resolve().parent
    result = subprocess.run(["node", "--test", str(root / "albums.test.mjs"), str(root / "favorites.test.mjs")], cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_live_anonymous_access_denied():
    from urllib.request import urlopen
    from urllib.error import HTTPError
    for path in ["/api/albums", "/api/albums/photos/not-a-photo", "/api/favorites", "/api/favorites/attachment/not-a-favorite/0"]:
        try:
            urlopen("http://127.0.0.1:8799" + path, timeout=3)
        except HTTPError as error:
            assert error.code == 401
        else:
            raise AssertionError("Private albums allowed anonymous access")


if __name__ == "__main__":
    test_shared_albums()
    test_live_anonymous_access_denied()
    print("11 isolated album/favorites tests and 4 live unauthorized-access checks passed")
