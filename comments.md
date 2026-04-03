Reduce nodes
A1, A2: exactly, we should assume that partitions are not necessarily based on an algorithmic approach, and instead assume a random distribution.

A3: we should assume that the default RF is 3, but it could happen that some topics have a lower amount of replicas. I sort of expect that we will have to go over the nodes and fetch all the correct data. One important detail: the cluster is a proper 3-region setup. This means that each region has 3 broker nodes. This would effectively - assuming we are aiming at recovering RF3 nodes, that we could in theory fetch a single region, then change enough metadata so it could work either with a single replica (all of them would have 1), as well as changing the metadata pertaining to rack awareness, etc. What do you think?

A4: 100% just by selecting a few broker nodes is indeed impossible given our constraints.

B1: agreed, but I already have a specific snapshot-based recovery runbook and rules to recover from a snapshot, as well as the assumption that data loss IS ACCEPTABLE AND EXPECTED, as long as we try to recover as much as we can.

C1: this is a big one, and we need to check how to address or rebuild consumer offsets

D1: our deployment is completely DevOps and gitops based. All nodes follow the same data, structure and even physical harnesses: same disks, same configurations, etc. 

D2: multiple log dirs is an important item that we should address.

D3: as previously explained, we can work with data loss;

E1: snapshots will be IBM hardware based, and close enough in time that data loss will be minimal - but still existent. Let’s assume data loss is acceptable.

F1: I think we need to review and rethink on new strategies based on the input and findings.

G1: we can assume tiered storage has not been setup nor will in the foreseeable future. We can work with that assumption.

H1: our recovery harness for transactions already covered recovering from transactions. As long as we can recover, or cancel transactions that were failed to abort, and then start a new transaction, we are fine with that - again, some data loss is acceptable.

I1: If we agree on my previous strategy, we can assume that we will have a trio of brokers that covers exactly one copy of each data entry, as we have 9 nodes, covering 3 regions, using proper rack awareness, meaning we should have most data available in a single set of 3 brokers. Assuming a happy path here is OK (e.g. we are assuming all 3 regions were working fine, and mostly up-to-date, etc).

I2: that’s important to keep, yes.

J1: ok, agreed

J2: we can assume we will always recover onto the same Kafka binary version - either the snapshot will include it, or we will be installing from the same version. It’s good to point out if we go with a manual/fresh install though.

K1: let’s leave this detail has a something to point out. It’s something we know how to solve, but it’s definitely important to solve later. But it’s not something that will make or break the implementation, and we won’t need it for our first few tests.

L1: agreed, we will need a validation step for this. We can work together LATER, after we validate our requirements and approach to recover a cluster;

L2: great point, let’s set it!

M1: good point, let’s make sure to include this detail

M2: good point. Based on my provided new detail, this may not be an issue (I.e. we use a full region, instead of looking for brokers), and keep it at 1RF. Alternatively, if we then want to explode replicas (either by then bootstrapping to 3 replicas again or maybe using a RF of 2), we do need to consider disk usage, as each disk would indeed use up more storage!

M3: we can ignore throttling for now.



