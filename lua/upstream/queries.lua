-- GraphQL documents. Lists share one item fragment per kind so the list rows
-- and the cache have the same shape whichever tab produced them.

local M = {}

local ISSUE_FIELDS = [[
  __typename number title state url updatedAt createdAt
  author { login }
  comments { totalCount }
  labels(first: 5) { nodes { name color } }
]]

local PR_FIELDS = [[
  __typename number title state url updatedAt createdAt isDraft
  headRefName baseRefName reviewDecision
  author { login }
  comments { totalCount }
  labels(first: 5) { nodes { name color } }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
]]

local PAGE = "pageInfo { hasNextPage endCursor } totalCount"

M.issues = ([[
query($owner: String!, $name: String!, $n: Int!, $cursor: String, $states: [IssueState!]) {
  repository(owner: $owner, name: $name) {
    items: issues(first: $n, after: $cursor, states: $states,
                  orderBy: { field: UPDATED_AT, direction: DESC }) {
      %s
      nodes { %s }
    }
  }
}]]):format(PAGE, ISSUE_FIELDS)

M.prs = ([[
query($owner: String!, $name: String!, $n: Int!, $cursor: String, $states: [PullRequestState!]) {
  repository(owner: $owner, name: $name) {
    items: pullRequests(first: $n, after: $cursor, states: $states,
                        orderBy: { field: UPDATED_AT, direction: DESC }) {
      %s
      nodes { %s }
    }
  }
}]]):format(PAGE, PR_FIELDS)

M.reviews = ([[
query($q: String!, $n: Int!, $cursor: String) {
  items: search(type: ISSUE, query: $q, first: $n, after: $cursor) {
    pageInfo { hasNextPage endCursor } totalCount: issueCount
    nodes { ... on PullRequest { %s } }
  }
}]]):format(PR_FIELDS)

M.header = [[
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN) { totalCount }
    pullRequests(states: OPEN) { totalCount }
    defaultBranchRef { target { ... on Commit { statusCheckRollup { state } } } }
  }
}]]

local TIMELINE = [[
  timelineItems(last: 50, itemTypes: [%s]) {
    totalCount
    nodes {
      __typename
      ... on IssueComment { author { login } createdAt body }
      ... on ClosedEvent { actor { login } createdAt }
      ... on ReopenedEvent { actor { login } createdAt }
      ... on CrossReferencedEvent {
        actor { login } createdAt
        source { __typename ... on Issue { number title } ... on PullRequest { number title } }
      }
      %s
    }
  }
]]

local COMMON = [[
  id number title state url body createdAt updatedAt
  author { login }
  comments { totalCount }
  labels(first: 20) { nodes { name color } }
  assignees(first: 10) { nodes { login } }
  milestone { title }
]]

-- Selections shared by the detail queries and every mutation's payload, so a
-- write returns exactly what a read would and can go straight into the cache.
M.ISSUE_DETAIL = ([[
  __typename stateReason %s
  %s
]]):format(COMMON, TIMELINE:format("ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, CROSS_REFERENCED_EVENT", ""))

M.PR_DETAIL = ([[
  __typename %s
  isDraft headRefName baseRefName reviewDecision mergeable headRefOid
  isCrossRepository headRef { id }
  additions deletions changedFiles
  reviewRequests(first: 10) {
    nodes { requestedReviewer { __typename ... on User { login id } ... on Team { name id } } }
  }
  closingIssuesReferences(first: 10) { nodes { number title } }
  commits(last: 1) { totalCount nodes { commit { statusCheckRollup { state } } } }
  approvals: reviews(states: APPROVED) { totalCount }
  %s
]]):format(COMMON, TIMELINE:format(
  "ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, CLOSED_EVENT, REOPENED_EVENT, MERGED_EVENT, CROSS_REFERENCED_EVENT",
  [[
      ... on PullRequestReview { author { login } createdAt body state }
      ... on PullRequestCommit { commit { abbreviatedOid messageHeadline committedDate author { user { login } name } } }
      ... on MergedEvent { actor { login } createdAt }
  ]]
))

-- `... on Issue { … } ... on PullRequest { … }` for payloads typed as a union
M.EITHER = ("... on Issue { %s } ... on PullRequest { %s }"):format(M.ISSUE_DETAIL, M.PR_DETAIL)

M.issue = ([[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    item: issue(number: $number) { %s }
  }
}]]):format(M.ISSUE_DETAIL)

M.pr = ([[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    item: pullRequest(number: $number) { %s }
  }
}]]):format(M.PR_DETAIL)

-- Everything the pickers and create mutations need: ids for labels, users
-- and milestones, plus the repository id and who "me" is.
M.meta = [[
query($owner: String!, $name: String!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    id
    labels(first: 100, orderBy: { field: NAME, direction: ASC }) { nodes { id name color description } }
    assignableUsers(first: 100) { nodes { id login name } }
    milestones(first: 50, states: OPEN, orderBy: { field: DUE_DATE, direction: ASC }) { nodes { id title } }
  }
}]]

-- ---------------------------------------------------------------------------
-- mutations (each returns the full detail of the item it touched)
-- ---------------------------------------------------------------------------

M.add_comment = ([[
mutation($id: ID!, $body: String!) {
  addComment(input: { subjectId: $id, body: $body }) { subject { %s } }
}]]):format(M.EITHER)

M.update_issue = ([[
mutation($id: ID!, $title: String, $body: String, $labelIds: [ID!], $assigneeIds: [ID!], $milestoneId: ID) {
  updateIssue(input: { id: $id, title: $title, body: $body, labelIds: $labelIds,
                       assigneeIds: $assigneeIds, milestoneId: $milestoneId }) { issue { %s } }
}]]):format(M.ISSUE_DETAIL)

M.update_pr = ([[
mutation($id: ID!, $title: String, $body: String, $base: String, $labelIds: [ID!], $assigneeIds: [ID!], $milestoneId: ID) {
  updatePullRequest(input: { pullRequestId: $id, title: $title, body: $body, baseRefName: $base,
                             labelIds: $labelIds, assigneeIds: $assigneeIds, milestoneId: $milestoneId }) {
    pullRequest { %s }
  }
}]]):format(M.PR_DETAIL)

M.close_issue = ([[
mutation($id: ID!, $reason: IssueClosedStateReason) {
  closeIssue(input: { issueId: $id, stateReason: $reason }) { issue { %s } }
}]]):format(M.ISSUE_DETAIL)

M.reopen_issue = ([[
mutation($id: ID!) { reopenIssue(input: { issueId: $id }) { issue { %s } } }]]):format(M.ISSUE_DETAIL)

M.close_pr = ([[
mutation($id: ID!) { closePullRequest(input: { pullRequestId: $id }) { pullRequest { %s } } }]]):format(M.PR_DETAIL)

M.reopen_pr = ([[
mutation($id: ID!) { reopenPullRequest(input: { pullRequestId: $id }) { pullRequest { %s } } }]]):format(M.PR_DETAIL)

M.request_reviews = ([[
mutation($id: ID!, $userIds: [ID!], $teamIds: [ID!]) {
  requestReviews(input: { pullRequestId: $id, userIds: $userIds, teamIds: $teamIds, union: false }) {
    pullRequest { %s }
  }
}]]):format(M.PR_DETAIL)

M.merge_pr = ([[
mutation($id: ID!, $method: PullRequestMergeMethod!) {
  mergePullRequest(input: { pullRequestId: $id, mergeMethod: $method }) { pullRequest { %s } }
}]]):format(M.PR_DETAIL)

M.mark_ready = ([[
mutation($id: ID!) { markPullRequestReadyForReview(input: { pullRequestId: $id }) { pullRequest { %s } } }]])
  :format(M.PR_DETAIL)

M.delete_ref = [[
mutation($id: ID!) { deleteRef(input: { refId: $id }) { clientMutationId } }]]

M.create_issue = ([[
mutation($repo: ID!, $title: String!, $body: String, $labelIds: [ID!], $assigneeIds: [ID!], $milestoneId: ID) {
  createIssue(input: { repositoryId: $repo, title: $title, body: $body, labelIds: $labelIds,
                       assigneeIds: $assigneeIds, milestoneId: $milestoneId }) { issue { %s } }
}]]):format(M.ISSUE_DETAIL)

M.create_pr = ([[
mutation($repo: ID!, $base: String!, $head: String!, $title: String!, $body: String, $draft: Boolean) {
  createPullRequest(input: { repositoryId: $repo, baseRefName: $base, headRefName: $head,
                             title: $title, body: $body, draft: $draft }) { pullRequest { %s } }
}]]):format(M.PR_DETAIL)

-- ---------------------------------------------------------------------------
-- review
-- ---------------------------------------------------------------------------

local THREAD = [[
  id isResolved isOutdated path line startLine diffSide startDiffSide originalLine subjectType
  comments(first: 50) { nodes { id author { login } body createdAt state } }
]]

M.review = ([[
query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id number title body url headRefOid baseRefName headRefName
      closingIssuesReferences(first: 5) { nodes { number title body } }
      reviewThreads(first: 100) { nodes { %s } }
      pending: reviews(states: PENDING, first: 1) { nodes { id author { login } } }
    }
  }
}]]):format(THREAD)

M.start_review = [[
mutation($pr: ID!, $oid: GitObjectID) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $oid }) { pullRequestReview { id } }
}]]

M.add_thread = ([[
mutation($review: ID!, $path: String!, $body: String!, $line: Int, $side: DiffSide,
         $startLine: Int, $startSide: DiffSide, $subjectType: PullRequestReviewThreadSubjectType) {
  addPullRequestReviewThread(input: { pullRequestReviewId: $review, path: $path, body: $body,
                                      line: $line, side: $side, startLine: $startLine,
                                      startSide: $startSide, subjectType: $subjectType }) {
    thread { %s }
  }
}]]):format(THREAD)

M.reply_thread = [[
mutation($thread: ID!, $body: String!, $review: ID) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body,
                                           pullRequestReviewId: $review }) {
    comment { id author { login } body createdAt state }
  }
}]]

M.resolve_thread = [[
mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }]]

M.unresolve_thread = [[
mutation($id: ID!) { unresolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }]]

M.submit_review = [[
mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: $event, body: $body }) {
    pullRequestReview { id state }
  }
}]]

-- a review with no pending comments (approve / comment / request changes
-- straight away)
M.review_now = [[
mutation($pr: ID!, $event: PullRequestReviewEvent!, $body: String) {
  addPullRequestReview(input: { pullRequestId: $pr, event: $event, body: $body }) {
    pullRequestReview { id state }
  }
}]]

M.discard_review = [[
mutation($id: ID!) { deletePullRequestReview(input: { pullRequestReviewId: $id }) { clientMutationId } }]]

return M
