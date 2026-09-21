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

    def test_postprocess_removes_unsupported_tts_tags(self) -> None:
        text = talk_engine.postprocess_talk_text("Tiny studio update [excited]: coffee survived.")
        self.assertEqual(text, "Tiny studio update: coffee survived.")

    def test_postprocess_keeps_supported_tts_tags(self) -> None:
        text = talk_engine.postprocess_talk_text("That one woke up the mixer. [Laugh]")
        self.assertEqual(text, "That one woke up the mixer. [laugh].")

    def test_postprocess_maps_breath_and_drops_whisper(self) -> None:
        text = talk_engine.postprocess_talk_text("Easy now [breath] here we go [whisper] softly.")
        self.assertEqual(text, "Easy now [sigh] here we go softly.")

    def test_postprocess_keeps_multiword_tag(self) -> None:
        text = talk_engine.postprocess_talk_text("Ahem [Clear Throat] welcome back.")
        self.assertEqual(text, "Ahem [clear throat] welcome back.")

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

        self.assertIn("Off-topic is okay in small doses", prompt)
        self.assertIn("SELECTED AIRBREAK BIT", prompt)
        self.assertIn("Do not make every talk a song review", prompt)
        self.assertIn("Never default to 'perfect time for music'", prompt)


class TalkLengthTest(unittest.TestCase):
    def _make_prompt(self, talk_length: str) -> str:
        pcfg = prompt_builder._get_personality("standard")
        return prompt_builder._build(
            context="[Optional live context, use rarely: evening]",
            pcfg=pcfg,
            next_track=TrackInfo(title="Night Owl", artist="Chromatics"),
            previous_track=TrackInfo(title="Drive", artist="Chromatics"),
            length_instruction=prompt_builder._LENGTH_INSTRUCTIONS[talk_length],
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

    def test_short_length_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("short")
        self.assertIn("18–30 words", prompt)

    def test_medium_length_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("medium")
        self.assertIn("35–60 words", prompt)

    def test_long_length_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("long")
        self.assertIn("70–100 words", prompt)

    def test_clamp_short_at_180_chars(self) -> None:
        long_text = "Word " * 60
        clamped = talk_engine.clamp_talk_length(long_text, "short")
        self.assertLessEqual(len(clamped), 180)

    def test_clamp_long_at_800_chars(self) -> None:
        long_text = "Word " * 200
        clamped = talk_engine.clamp_talk_length(long_text, "long")
        self.assertLessEqual(len(clamped), 800)


class PersonalityTest(unittest.TestCase):
    def _make_prompt(self, personality: str) -> str:
        pcfg = prompt_builder._get_personality(personality)
        return prompt_builder._build(
            context="[Optional live context, use rarely: night]",
            pcfg=pcfg,
            next_track=TrackInfo(title="Blue Monday", artist="New Order"),
            previous_track=None,
            length_instruction=prompt_builder._LENGTH_INSTRUCTIONS["medium"],
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

    def test_comedian_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("comedian")
        self.assertIn("funny music radio DJ", prompt)
        self.assertIn("The track intro is still the payoff", prompt)

    def test_intellectual_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("intellectual")
        self.assertIn("thoughtful music radio DJ", prompt)

    def test_energetic_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("energetic")
        self.assertIn("upbeat drive-time", prompt)

    def test_chill_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("chill")
        self.assertIn("mellow late-night", prompt)

    def test_standard_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("standard")
        self.assertIn("warm music radio DJ", prompt)

    def test_unknown_personality_falls_back_to_standard(self) -> None:
        pcfg = prompt_builder._get_personality("nonexistent")
        self.assertEqual(pcfg["persona"], prompt_builder._PERSONALITIES["standard"]["persona"])

    def test_each_personality_has_house_rules(self) -> None:
        for name, cfg in prompt_builder._PERSONALITIES.items():
            self.assertIn("house_rules", cfg, f"Missing house_rules for personality: {name}")
            self.assertTrue(cfg["house_rules"].strip(), f"Empty house_rules for personality: {name}")

    def test_each_personality_uses_only_supported_tts_tags(self) -> None:
        supported = {f"[{t}]" for t in talk_engine._SUPPORTED_TTS_TAGS}
        for name, cfg in prompt_builder._PERSONALITIES.items():
            tags = [
                token.strip()
                for token in cfg["emotions"].splitlines()
                if token.strip()
            ]
            self.assertTrue(tags, f"No TTS tags for personality: {name}")
            for tag in tags:
                self.assertIn(tag, supported, f"Unsupported TTS tag for {name}: {tag}")

    def test_album_included_in_track_label(self) -> None:
        track = TrackInfo(title="Karma Police", artist="Radiohead", album="OK Computer")
        label = prompt_builder._track_label(track)
        self.assertIn("OK Computer", label)

    def test_album_omitted_when_none(self) -> None:
        track = TrackInfo(title="Karma Police", artist="Radiohead")
        label = prompt_builder._track_label(track)
        self.assertNotIn("from", label)


class LanguageTest(unittest.TestCase):
    def test_prompt_is_english_only(self) -> None:
        import asyncio
        prompt = asyncio.run(
            prompt_builder.build_prompt(
                next_track=TrackInfo(title="Blue Monday", artist="New Order"),
                previous_track=None,
                talk_length="medium",
                cfg={},
            )
        )
        self.assertIn("natural English", prompt)
        self.assertNotIn("Japanese", prompt)


if __name__ == "__main__":
    unittest.main()


class WebContextPromptTest(unittest.TestCase):
    def _build(self, facts: str, mid: bool = False) -> str:
        return prompt_builder._build(
            context="ctx",
            pcfg=prompt_builder._PERSONALITIES["standard"],
            next_track=TrackInfo(title="Next", artist="Artist"),
            previous_track=TrackInfo(title="Prev", artist="Other"),
            length_instruction="Keep it short.",
            is_mid_song=mid,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
            artist_facts=facts,
        )

    def test_facts_become_artist_spotlight(self) -> None:
        for mid in (False, True):
            prompt = self._build("Recent headlines:\n- Artist announces tour", mid)
            self.assertIn("artist spotlight", prompt)
            self.assertIn("Artist announces tour", prompt)

    def test_no_facts_uses_regular_bit(self) -> None:
        self.assertNotIn("artist spotlight", self._build(""))

    def test_settings_default_disabled(self) -> None:
        import services.web_context as web_context
        self.assertFalse(web_context.settings({})["enabled"])
        self.assertTrue(web_context.settings({"dj": {"web_search": {"enabled": True}}})["enabled"])
