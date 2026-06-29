from __future__ import annotations

import sys
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))

from models.schemas import TrackInfo  # noqa: E402
import services.program_memory as program_memory  # noqa: E402
import services.prompt_builder as prompt_builder  # noqa: E402
import services.talk_engine as talk_engine  # noqa: E402


class TalkEngineTest(unittest.TestCase):
    def test_postprocess_removes_closing_language(self) -> None:
        text = talk_engine.postprocess_talk_text("That wraps it up, until next time")
        self.assertEqual(text, "Here comes the next track.")

    def test_postprocess_adds_sentence_punctuation(self) -> None:
        text = talk_engine.postprocess_talk_text("Coming up next is a bright one")
        self.assertEqual(text, "Coming up next is a bright one.")

    def test_clamp_talk_length_prefers_sentence_boundary(self) -> None:
        source = "First sentence. " + ("Second sentence is too long " * 20)
        text = talk_engine.clamp_talk_length(source, "short")
        self.assertLessEqual(len(text), 180)
        self.assertTrue(text.endswith("."))


class ProgramMemoryTest(unittest.TestCase):
    def test_prompt_guidance_mentions_recent_talk(self) -> None:
        program_memory.remember_talk(
            text="A clean little radio break for the afternoon.",
            next_track=TrackInfo(title="Next", artist="Artist"),
            previous_track=TrackInfo(title="Prev", artist="Artist"),
        )

        guidance = program_memory.prompt_guidance()

        self.assertIn("PROGRAM MEMORY", guidance)
        self.assertIn("radio break", guidance)


class PromptBuilderTest(unittest.TestCase):
    def test_prompt_encourages_off_topic_airbreaks(self) -> None:
        prompt = prompt_builder._build(
            context="[Optional live context, use rarely: afternoon]",
            pcfg={
                "persona": "a radio DJ",
                "style": "Loose and funny.",
                "joke_rate": 1.0,
                "emotions": "(laugh)",
            },
            next_track=TrackInfo(title="Next", artist="Artist"),
            previous_track=TrackInfo(title="Prev", artist="Artist"),
            length_instruction="Keep it short.",
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

        self.assertIn("Off-topic is good", prompt)
        self.assertIn("SELECTED AIRBREAK BIT", prompt)
        self.assertIn("Do not make every talk a song review", prompt)
        self.assertIn("Never default to 'perfect weather/time for music'", prompt)


if __name__ == "__main__":
    unittest.main()
