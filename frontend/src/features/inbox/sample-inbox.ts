type Copy = { "en-US": string; "zh-CN": string };

export type InboxTask = {
  title: Copy;
  description: Copy;
  assignee: Copy;
  status: "doing" | "done";
};

export type InboxMessage = {
  id: string;
  sentAt: string;
  direction: "incoming" | "outgoing";
  text: Copy | string;
  unread?: true;
  task?: InboxTask;
};

export type InboxConversation = {
  id: string;
  name: Copy;
  messages: readonly [InboxMessage, ...InboxMessage[]];
};

const lin = { "en-US": "Tao Lin", "zh-CN": "林涛" };
const xu = { "en-US": "Yu Xu", "zh-CN": "许昱" };
const chen = { "en-US": "An Chen", "zh-CN": "陈安" };

export const sampleConversations: readonly InboxConversation[] = [
  {
    id: "lin",
    name: lin,
    messages: [
      {
        id: "lin-1",
        sentAt: "2026-11-21T02:13:00Z",
        direction: "incoming",
        text: {
          "en-US":
            "Can you take a look at the workbench navigation before the review?",
          "zh-CN": "评审前能帮忙看一眼工作台导航吗？",
        },
      },
      {
        id: "lin-2",
        sentAt: "2026-11-21T02:18:00Z",
        direction: "outgoing",
        text: {
          "en-US":
            "Sure. I'll check the layout with a task open and the sidebar collapsed.",
          "zh-CN": "可以。我会检查打开任务和收起左栏的效果。",
        },
      },
      {
        id: "lin-3",
        sentAt: "2026-11-21T02:36:00Z",
        direction: "incoming",
        unread: true,
        text: {
          "en-US": "I added the review notes to this task.",
          "zh-CN": "我把要看的几个点记到这条任务里了。",
        },
        task: {
          title: {
            "en-US": "Review workbench navigation",
            "zh-CN": "评审工作台导航",
          },
          description: {
            "en-US":
              "Check task selection, the collapsed sidebar, and keyboard navigation at desktop and narrow widths. Record any issues under this task.",
            "zh-CN":
              "在桌面宽度和窄窗下检查任务切换、左栏收起和键盘导航。发现的问题记到这条任务下。",
          },
          assignee: lin,
          status: "doing",
        },
      },
      {
        id: "lin-4",
        sentAt: "2026-11-21T02:42:00Z",
        direction: "incoming",
        unread: true,
        text: {
          "en-US": "Please include the narrow window in the review.",
          "zh-CN": "窄窗口的效果也麻烦一起看一下。",
        },
      },
    ],
  },
  {
    id: "xu",
    name: xu,
    messages: [
      {
        id: "xu-1",
        sentAt: "2026-11-21T01:46:00Z",
        direction: "incoming",
        unread: true,
        text: {
          "en-US": "The sample workspace is ready for the demo.",
          "zh-CN": "演示用的示例工作区已经准备好了。",
        },
        task: {
          title: {
            "en-US": "Prepare the demo workspace",
            "zh-CN": "准备演示工作区",
          },
          description: {
            "en-US":
              "Prepare a sample project with a recent task and a completed run so the workbench can be shown without using a real project.",
            "zh-CN":
              "准备一个含最近任务和已完成运行的示例项目，用于工作台演示。",
          },
          assignee: xu,
          status: "done",
        },
      },
    ],
  },
  {
    id: "chen",
    name: chen,
    messages: [
      {
        id: "chen-1",
        sentAt: "2026-11-20T08:18:00Z",
        direction: "incoming",
        text: {
          "en-US": "Thanks, I have the walkthrough for tomorrow.",
          "zh-CN": "收到，明天评审的演示流程我已经看过了。",
        },
      },
    ],
  },
];
