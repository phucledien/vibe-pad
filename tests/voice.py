"""Exercise draft and submission behavior without a controller or agent account."""
import contextlib
import io
from pathlib import Path
import runpy
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
vibe = runpy.run_path(str(Path(__file__).resolve().parents[1] / "vibe"))
Agent = vibe["Agent"]


class VoiceControls(unittest.TestCase):
    def test_herdr_sends_literal_argument(self):
        target = "w3:p2"
        text = 'Check "main.m" and explain $(version).'
        agent = Agent(SimpleNamespace(herdr=target, preview=False))
        with patch.object(subprocess, "run") as run:
            agent.send(text)
        run.assert_called_once_with(["herdr", "agent", "prompt", target, text], check=True)

    def test_claude_conversation_continues(self):
        agent = Agent(SimpleNamespace(herdr=None, preview=False))
        with patch.object(subprocess, "run") as run:
            agent.send("first")
            agent.send("second")
        first, second = run.call_args_list
        self.assertEqual(first.args[0], ["claude", "-p", "--session-id", agent.session])
        self.assertEqual(second.args[0], ["claude", "-p", "--resume", agent.session])
        self.assertEqual(second.kwargs["input"], "second")

    def test_discard_replace_and_submit_once(self):
        args = SimpleNamespace(herdr="test", preview=False, model=Path(__file__),
                               language="vi", talk="r2", send="square", discard="circle")
        events = iter([0, 11, 10, 0, 0, 10, 10, 130])
        def run(argv, **kwargs):
            if argv[:3] == ["herdr", "agent", "get"]:
                return SimpleNamespace(returncode=0, stdout='{"result":{"agent":{"agent":"claude","cwd":"/repo","pane_id":"p2"}}}')
            return SimpleNamespace(returncode=next(events) if "--agent-input" in argv else 0)
        agent = Mock()
        main = vibe["main"]
        with patch.dict(main.__globals__, options=lambda: args, Agent=lambda _: agent,
                        transcribe=Mock(side_effect=["discard me", "replace me", "ship this"])), \
             patch.object(subprocess, "run", side_effect=run), \
             patch("shutil.which", return_value="/bin/tool"), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(), 130)
        agent.send.assert_called_once_with("ship this")


if __name__ == "__main__":
    unittest.main()
