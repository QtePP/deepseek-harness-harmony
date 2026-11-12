import { describe, it, expect } from '@ohos/hypium';
import { hasSecret, maskSecrets, secretCount } from '../main/ets/common/SecretMask';
import { fontIdOf, fontScaleOf, scaled } from '../main/ets/common/Typography';
import { activeTodo, completedCount, isTodoTool, todosFromJson, todoSummary } from '../main/ets/model/TodoModel';
import { goalFromJson, goalSettled, goalStatusLabel, isGoalTool } from '../main/ets/model/GoalModel';

/**
 * Tests for the pure projections and formatters.
 *
 * These are the modules whose bugs are silent: a mask that hides the wrong
 * span, a todo list that parses to nothing, a goal that forgets it was paused.
 * None of them needs a device, so they belong in the host-side suite that runs
 * before every deploy.
 */
export default function localUnitTest() {
  describe('SecretMask', () => {
    it('masks an API key to its first eight characters', 0, () => {
      const masked = maskSecrets('key is sk-abcdefghijklmnop and that is it');
      expect(masked).assertContain('sk-abcde…');
      expect(masked.indexOf('sk-abcdefghijklmnop') < 0).assertTrue();
    });

    it('leaves prose without credentials untouched', 0, () => {
      const text = 'nothing secret here, just words';
      expect(maskSecrets(text)).assertEqual(text);
      expect(hasSecret(text)).assertFalse();
    });

    it('counts every credential in one message', 0, () => {
      const text = 'sk-aaaaaaaaaaaaaaaa and sk-bbbbbbbbbbbbbbbb';
      expect(secretCount(text)).assertEqual(2);
      expect(hasSecret(text)).assertTrue();
    });

    it('does not mask a bare word that merely starts with sk', 0, () => {
      const text = 'sk-short';
      expect(maskSecrets(text)).assertEqual(text);
      expect(hasSecret(text)).assertFalse();
    });
  });

  describe('Typography', () => {
    it('maps a level id to its multiplier', 0, () => {
      expect(fontScaleOf('xlarge')).assertEqual(1.3);
      expect(fontScaleOf('standard')).assertEqual(1);
    });

    it('falls back to standard for an unknown level', 0, () => {
      expect(fontScaleOf('gigantic')).assertEqual(1);
      expect(fontIdOf(1)).assertEqual('standard');
    });

    it('rounds a scaled size to a half point', 0, () => {
      expect(scaled(15, 1.3)).assertEqual(19.5);
      // 12 * 0.9 = 10.8, which rounds to the nearest half point (11).
      expect(scaled(12, 0.9)).assertEqual(11);
      expect(scaled(13, 1)).assertEqual(13);
    });
  });

  describe('TodoModel', () => {
    it('recognises the todo tool by name', 0, () => {
      expect(isTodoTool('todo_write')).assertTrue();
      expect(isTodoTool('glob')).assertFalse();
    });

    it('parses a whole-list snapshot', 0, () => {
      const todos = todosFromJson('{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"in_progress"}]}');
      expect(todos === null).assertFalse();
      if (todos !== null) {
        expect(todos.length).assertEqual(2);
        expect(completedCount(todos)).assertEqual(1);
        expect(activeTodo(todos)).assertEqual('b');
      }
    });

    it('rejects unknown statuses instead of guessing', 0, () => {
      const todos = todosFromJson('{"todos":[{"content":"a","status":"doing"}]}');
      expect(todos === null).assertFalse();
      if (todos !== null) {
        expect(todos.length).assertEqual(0);
      }
    });

    it('returns null for text that is not a todo snapshot', 0, () => {
      expect(todosFromJson('not json') === null).assertTrue();
      expect(todosFromJson('{"pattern":"**/*"}') === null).assertTrue();
    });

    it('summarises progress and the current step', 0, () => {
      const todos = todosFromJson(
        '{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"pending"}]}');
      if (todos !== null) {
        expect(todoSummary(todos)).assertContain('1/2');
        expect(todoSummary(todos)).assertContain('two');
      }
    });
  });

  describe('GoalModel', () => {
    it('recognises the goal tools', 0, () => {
      expect(isGoalTool('create_goal')).assertTrue();
      expect(isGoalTool('update_goal')).assertTrue();
      expect(isGoalTool('glob')).assertFalse();
    });

    it('creates an active goal from create_goal', 0, () => {
      const goal = goalFromJson(null, 'create_goal', '{"objective":"ship it"}');
      expect(goal === null).assertFalse();
      if (goal !== null) {
        expect(goal.objective).assertEqual('ship it');
        expect(goal.status).assertEqual('active');
        expect(goalSettled(goal.status)).assertFalse();
      }
    });

    it('applies pause, resume and complete to the standing goal', 0, () => {
      const created = goalFromJson(null, 'create_goal', '{"objective":"x"}');
      const paused = goalFromJson(created, 'update_goal', '{"action":"pause"}');
      if (paused !== null) {
        expect(paused.status).assertEqual('paused');
        expect(goalStatusLabel(paused.status)).assertEqual('已暂停');
      }
      const done = goalFromJson(paused, 'update_goal', '{"action":"complete"}');
      if (done !== null) {
        expect(done.status).assertEqual('completed');
        expect(done.objective).assertEqual('x');
        expect(goalSettled(done.status)).assertTrue();
      }
    });

    it('replaces the objective on edit and ignores read-only calls', 0, () => {
      const created = goalFromJson(null, 'create_goal', '{"objective":"old"}');
      const edited = goalFromJson(created, 'update_goal', '{"action":"edit","objective":"new"}');
      if (edited !== null) {
        expect(edited.objective).assertEqual('new');
      }
      expect(goalFromJson(created, 'get_goal', '{}') === null).assertTrue();
    });
  });
}
