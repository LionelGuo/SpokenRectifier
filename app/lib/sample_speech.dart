/// Canned demo content for the fake-driven shell: sentences "recognized"
/// while recording, and the rectified texts the fake LLM queues.

library;

const sampleUtterance = <String>[
  '呃那个,我想说一下昨天开会的事,',
  '就是那个 v2 的发布计划,不对,是 v3 的发布计划,',
  '首先时间上,大概六月二十一号上线,再补充一点,是下午三点,不是上午,',
  '然后预算这块儿,大概要花一百二十万的样子,其中百分之三十是给外包的,',
  '对了,还要通知运维的同学提前做好扩容,嗯,就这样,没了。',
];

const sampleRectified = <String>[
  '关于昨天会议讨论的 v3 发布计划:预计 6 月 21 日下午 3:00 上线;预算约 120 万元,'
      '其中 30% 用于外包。需提前通知运维团队做好扩容准备。',
  'v3 发布计划(6 月 21 日 15:00 上线):预算 120 万元,外包占 30%;上线前通知运维扩容。',
  '昨天会议确认:v3 发布计划 6 月 21 日下午三点上线,预算一百二十万(30% 外包),运维需提前扩容。',
];
