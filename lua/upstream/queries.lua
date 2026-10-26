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
  number title state url body createdAt updatedAt
  author { login }
  labels(first: 20) { nodes { name color } }
  assignees(first: 10) { nodes { login } }
  milestone { title }
]]

M.issue = ([[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    item: issue(number: $number) {
      __typename %s
      %s
    }
  }
}]]):format(COMMON, TIMELINE:format("ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, CROSS_REFERENCED_EVENT", ""))

M.pr = ([[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    item: pullRequest(number: $number) {
      __typename %s
      isDraft headRefName baseRefName reviewDecision mergeable
      additions deletions changedFiles
      reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
      closingIssuesReferences(first: 10) { nodes { number title } }
      commits(last: 1) { totalCount nodes { commit { statusCheckRollup { state } } } }
      approvals: reviews(states: APPROVED) { totalCount }
      %s
    }
  }
}]]):format(COMMON, TIMELINE:format(
  "ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, CLOSED_EVENT, REOPENED_EVENT, MERGED_EVENT, CROSS_REFERENCED_EVENT",
  [[
      ... on PullRequestReview { author { login } createdAt body state }
      ... on PullRequestCommit { commit { abbreviatedOid messageHeadline committedDate author { user { login } name } } }
      ... on MergedEvent { actor { login } createdAt }
  ]]
))

return M
