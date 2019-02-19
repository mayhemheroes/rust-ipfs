//! IPFS repo
use crate::block::{Cid, Block};
use crate::IpfsOptions;
use std::marker::PhantomData;
use std::path::PathBuf;

pub mod mem;
pub mod fs;

pub trait RepoTypes {
    type TBlockStore: BlockStore;
    type TDataStore: DataStore;
    type TRepo: Repo<Self::TBlockStore, Self::TDataStore>;
}

#[derive(Clone, Debug)]
pub struct RepoOptions<TRepoTypes: RepoTypes> {
    _marker: PhantomData<TRepoTypes>,
    path: PathBuf,
}

impl<TRepoTypes: RepoTypes> From<&IpfsOptions> for RepoOptions<TRepoTypes> {
    fn from(options: &IpfsOptions) -> Self {
        RepoOptions {
            _marker: PhantomData,
            path: options.ipfs_path.clone(),
        }
    }
}

pub fn create_repo<TRepoTypes: RepoTypes>(options: RepoOptions<TRepoTypes>) -> TRepoTypes::TRepo {
    TRepoTypes::TRepo::new(
        TRepoTypes::TBlockStore::new(options.path.clone()),
        TRepoTypes::TDataStore::new(options.path),
    )
}


pub trait BlockStore: Clone + Send {
    fn new(path: PathBuf) -> Self;
    fn contains(&self, cid: &Cid) -> bool;
    fn get(&self, cid: &Cid) -> Option<Block>;
    fn put(&self, block: Block) -> Cid;
    fn remove(&self, cid: &Cid);
}

pub trait DataStore: Clone + Send {
    fn new(path: PathBuf) -> Self;
}

pub trait Repo<BS: BlockStore, DS: DataStore>: Clone + Send {
    fn new(block_store: BS, data_store: DS) -> Self;
    fn init(&mut self);
    fn open(&mut self);
    fn close(&mut self);
    fn exists(&self) -> bool;
    fn blocks(&self) -> &BS;
    fn data(&self) -> &DS;
}

#[derive(Clone, Debug)]
pub struct IpfsRepo<BS: BlockStore, DS: DataStore> {
    block_store: BS,
    data_store: DS,
}

impl<BS: BlockStore, DS: DataStore> Repo<BS, DS> for IpfsRepo<BS, DS> {
    fn new(block_store: BS, data_store: DS) -> Self {
        IpfsRepo {
            block_store,
            data_store,
        }
    }

    fn init(&mut self) {

    }

    fn open(&mut self) {

    }

    fn close(&mut self) {

    }

    fn exists(&self) -> bool {
        false
    }

    fn blocks(&self) -> &BS {
        &self.block_store
    }

    fn data(&self) -> &DS {
        &self.data_store
    }
}
