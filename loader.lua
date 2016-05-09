require 'nn'
require 'torch'
require 'lmdb'

--[[

    this file defines a loader that load one batch on each call

--]]

local indexer = torch.class('indexer')

function indexer:__init(_dir, batch_size)

    self.db_spect = lmdb.env{Path=_dir..'/train_spect',Name='train_spect'}
    self.db_label = lmdb.env{Path=_dir..'/train_label',Name='train_label'}
    self.db_trans = lmdb.env{Path=_dir..'/train_trans',Name='train_trans'}

    self.batch_size = batch_size
    self.cnt = 1

    -- get the size of lmdb
    self.db_spect:open()
    self.db_label:open()
    self.db_trans:open()
    local l1 = self.db_spect:stat()['entries']
    local l2 = self.db_label:stat()['entries']
    local l3 = self.db_trans:stat()['entries']

    assert(l1 == l2 and l2 == l3, 'data sizes in each lmdb must agree')

    self.lmdb_size = l1

    self.db_spect:close()
    self.db_label:close()
    self.db_trans:close()

    assert(self.lmdb_size > self.batch_size, 'batch_size larger than lmdb_size')

end

function indexer:nxt_inds()
    --[[
        return indexs of next batch
    --]]

    local inds = {}
    if self.lmdb_size > self.cnt + self.batch_size - 1 then
        for i=0,self.batch_size-1 do
            table.insert(inds,self.cnt+i)
        end

        self.cnt = self.cnt + self.batch_size
        return inds
    end

    -- case where cnt+size >= total size
    for i=self.cnt,self.lmdb_size do
        table.insert(inds,i)
    end

    self.cnt = self.batch_size - (self.lmdb_size - self.cnt)
    for i=1, self.cnt-1 do -- overflow inds
        table.insert(inds,i)
    end

    return inds

end

local loader = torch.class('loader')

function loader:__init(_dir)
    --[[
        _dir: dir contains 3 lmdbs
    --]]

    self.db_spect = lmdb.env{Path=_dir..'/train_spect',Name='train_spect'}
    self.db_label = lmdb.env{Path=_dir..'/train_label',Name='train_label'}
    self.db_trans = lmdb.env{Path=_dir..'/train_trans',Name='train_trans'}
end

function loader:nxt_batch(inds, flag)
    --[[
        return a batch by loading from lmdb just-in-time

        flag: indicates whether to load trans

        TODO we allocate 2 * batch_size space
    --]]

    local tensor_list = {}
    local label_list = {}
    local max_w = 0
    local h = 0

    local trans_list = {}
    local txn_trans
    
    self.db_spect:open();local txn_spect = self.db_spect:txn(true) -- readonly
    self.db_label:open();local txn_label = self.db_label:txn(true)
    if flag then self.db_trans:open();txn_trans = self.db_trans:txn(true) end
    

    -- reads out a batch and store in lists
    for _, ind in next, inds, nil do
        local tensor = txn_spect:get(ind):double()
        local label = torch.deserialize(txn_label:get(ind))
        
        h = tensor:size(1)
        if max_w < tensor:size(2) then max_w = tensor:size(2) end -- find the max len in this batch

        table.insert(tensor_list, tensor)
        table.insert(label_list, label)
        if flag then table.insert(trans_list, torch.deserialize(txn_trans:get(ind))) end
    end

    -- store tensors into a fixed len tensor_array [TODO should find a better way to do this]
    local tensor_array = torch.Tensor(#inds, 1, h, max_w)
    for ind, tensor in ipairs(tensor_list) do
        tensor_array[ind][1]:narrow(2, 1, tensor:size(2)):copy(tensor)
    end

    txn_spect:abort();self.db_spect:close()
    txn_label:abort();self.db_label:close()
    if flag then txn_trans:abort();self.db_trans:close() end
    
    if flag then return tensor_array, label_list, trans_list end
    return tensor_array, label_list

end
