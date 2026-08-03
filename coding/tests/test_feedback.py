from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from accio_cu_code.feedback import (
    build_execution_feedback,
    is_mutating_tool,
    project_call_feedback,
)


def result(
    *,
    app="Finder",
    snapshot_id="snapshot-1",
    changed="confirmed",
    is_error=False,
):
    return {
        "content": [{"type": "text", "text": "AXDIFF must stay internal"}],
        "isError": is_error,
        "structuredContent": {
            "state": {
                "app": app,
                "bundle_id": "com.apple.finder",
                "pid": 42,
                "window_id": 7,
                "window_title": "Documents",
                "snapshot_id": snapshot_id,
                "ignored": "not exposed",
            },
            "action": {
                "tool": "click",
                "route": "ax_press",
                "changed": changed,
            },
        },
    }


class FeedbackTests(unittest.TestCase):
    def test_mutation_detection_prefers_annotations_with_legacy_name_fallback(self):
        self.assertTrue(
            is_mutating_tool({"name": "click", "annotations": {}})
        )
        self.assertTrue(
            is_mutating_tool(
                {"name": "click", "annotations": {"destructiveHint": False}}
            )
        )
        self.assertFalse(
            is_mutating_tool(
                {
                    "name": "wait_for_element",
                    "annotations": {"destructiveHint": False},
                }
            )
        )
        self.assertFalse(
            is_mutating_tool({"name": "get_app_state", "annotations": {}})
        )

    def test_latest_mutation_observation_is_compact(self):
        event = project_call_feedback(
            index=1,
            tool="click",
            is_mutation=True,
            result=result(),
            artifact_paths=["/tmp/call-0001.png"],
        )

        feedback = build_execution_feedback([event])

        self.assertEqual(
            feedback["mutations"],
            {
                "attempted": 1,
                "succeeded": 1,
                "failed": 0,
                "no_ax_change": 0,
                "unverifiable": 0,
            },
        )
        observation = feedback["latest_observation"]
        self.assertEqual(observation["source_call_index"], 1)
        self.assertEqual(observation["freshness"], "after_latest_mutation")
        self.assertEqual(observation["state"]["snapshot_id"], "snapshot-1")
        self.assertNotIn("ignored", observation["state"])
        self.assertEqual(
            observation["screenshot"],
            {"path": "/tmp/call-0001.png", "mime_type": "image/png"},
        )
        self.assertNotIn("text", str(feedback))
        self.assertNotIn("AXDIFF", str(feedback))

    def test_later_observation_can_refresh_the_latest_mutation(self):
        mutation = project_call_feedback(
            index=1,
            tool="click",
            is_mutation=True,
            result=result(snapshot_id="snapshot-1"),
            artifact_paths=["/tmp/call-0001.png"],
        )
        observation = project_call_feedback(
            index=2,
            tool="get_app_state",
            is_mutation=False,
            result=result(snapshot_id="snapshot-2"),
            artifact_paths=["/tmp/call-0002.png"],
        )

        feedback = build_execution_feedback([mutation, observation])

        latest = feedback["latest_observation"]
        self.assertEqual(latest["source_call_index"], 2)
        self.assertEqual(latest["state"]["snapshot_id"], "snapshot-2")
        self.assertEqual(latest["screenshot"]["path"], "/tmp/call-0002.png")

    def test_state_only_followup_keeps_new_state_and_earlier_screenshot(self):
        mutation = project_call_feedback(
            index=1,
            tool="click",
            is_mutation=True,
            result=result(snapshot_id="snapshot-1"),
            artifact_paths=["/tmp/call-0001.png"],
        )
        state_only = project_call_feedback(
            index=2,
            tool="get_app_state",
            is_mutation=False,
            result=result(snapshot_id="snapshot-2"),
        )

        latest = build_execution_feedback([mutation, state_only])["latest_observation"]

        self.assertEqual(latest["source_call_index"], 2)
        self.assertEqual(latest["state"]["snapshot_id"], "snapshot-2")
        self.assertEqual(latest["state_source_call_index"], 2)
        self.assertEqual(latest["screenshot_source_call_index"], 1)
        self.assertEqual(latest["screenshot"]["path"], "/tmp/call-0001.png")

    def test_screenshot_only_followup_is_the_primary_observation_source(self):
        mutation = project_call_feedback(
            index=1,
            tool="click",
            is_mutation=True,
            result=result(snapshot_id="snapshot-1"),
        )
        failed_mutation = project_call_feedback(
            index=2,
            tool="click",
            is_mutation=True,
            error={"type": "ToolError", "message": "target became stale"},
        )
        screenshot_only = project_call_feedback(
            index=3,
            tool="screenshot",
            is_mutation=False,
            result={},
            artifact_paths=["/tmp/call-0003.png"],
        )

        latest = build_execution_feedback(
            [mutation, failed_mutation, screenshot_only]
        )["latest_observation"]

        self.assertEqual(latest["source_call_index"], 3)
        self.assertEqual(latest["source_tool"], "screenshot")
        self.assertEqual(latest["freshness"], "before_failed_mutation")
        self.assertEqual(latest["state_source_call_index"], 1)
        self.assertEqual(latest["state_source_tool"], "click")
        self.assertEqual(latest["state_freshness"], "before_failed_mutation")
        self.assertEqual(latest["screenshot_source_call_index"], 3)
        self.assertEqual(latest["screenshot_source_tool"], "screenshot")
        self.assertEqual(
            latest["screenshot_freshness"], "after_latest_mutation"
        )

    def test_observation_only_block_has_no_execution_feedback(self):
        observation = project_call_feedback(
            index=1,
            tool="get_app_state",
            is_mutation=False,
            result=result(),
            artifact_paths=["/tmp/call-0001.png"],
        )

        self.assertIsNone(build_execution_feedback([observation]))

    def test_notifications_cover_all_mutations(self):
        no_ax_change = project_call_feedback(
            index=1,
            tool="click",
            is_mutation=True,
            result=result(changed="none", snapshot_id="snapshot-1"),
            artifact_paths=["/tmp/call-0001.png"],
        )
        confirmed = project_call_feedback(
            index=2,
            tool="click",
            is_mutation=True,
            result=result(changed="confirmed", snapshot_id="snapshot-2"),
            artifact_paths=["/tmp/call-0002.png"],
        )

        feedback = build_execution_feedback([no_ax_change, confirmed])

        self.assertEqual(feedback["mutations"]["attempted"], 2)
        self.assertEqual(feedback["mutations"]["no_ax_change"], 1)
        self.assertEqual(feedback["latest_observation"]["source_call_index"], 2)
        self.assertEqual(
            feedback["notifications"],
            [{"kind": "no_ax_change", "call_index": 1, "tool": "click"}],
        )

    def test_notification_list_is_bounded_and_reports_omissions(self):
        events = [
            project_call_feedback(
                index=index,
                tool="click",
                is_mutation=True,
                result=result(changed="none", snapshot_id="snapshot-%d" % index),
                artifact_paths=["/tmp/call-%04d.png" % index],
            )
            for index in range(1, 11)
        ]

        notifications = build_execution_feedback(events)["notifications"]

        self.assertEqual(len(notifications), 8)
        self.assertEqual(notifications[0]["kind"], "notifications_truncated")
        self.assertEqual(notifications[0]["omitted"], 3)
        self.assertEqual(notifications[-1]["call_index"], 10)

    def test_notification_truncation_preserves_latest_failure_and_staleness(self):
        earlier = [
            project_call_feedback(
                index=index,
                tool="click",
                is_mutation=True,
                result=result(changed="none", snapshot_id="snapshot-%d" % index),
                artifact_paths=["/tmp/call-%04d.png" % index],
            )
            for index in range(1, 9)
        ]
        failed = project_call_feedback(
            index=9,
            tool="click",
            is_mutation=True,
            error={"type": "ToolError", "message": "stale"},
        )

        notifications = build_execution_feedback([*earlier, failed])["notifications"]

        self.assertEqual(notifications[0]["kind"], "notifications_truncated")
        self.assertEqual(
            [item["kind"] for item in notifications[-2:]],
            ["action_error", "observation_may_be_stale"],
        )

    def test_failed_latest_mutation_marks_fallback_observation_stale(self):
        successful = project_call_feedback(
            index=1,
            tool="click",
            is_mutation=True,
            result=result(),
            artifact_paths=["/tmp/call-0001.png"],
        )
        failed = project_call_feedback(
            index=2,
            tool="click",
            is_mutation=True,
            error={"type": "ToolError", "message": "target became stale"},
        )

        feedback = build_execution_feedback([successful, failed])

        self.assertEqual(feedback["mutations"]["failed"], 1)
        self.assertEqual(
            feedback["latest_observation"]["freshness"],
            "before_failed_mutation",
        )
        self.assertEqual(
            [item["kind"] for item in feedback["notifications"]],
            ["action_error", "observation_may_be_stale"],
        )


if __name__ == "__main__":
    unittest.main()
